package bridge

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "lib:odin-http"
import http_client "lib:odin-http/client"

// Cap on the response body the HTTP client is willing to allocate for a
// single request. odin-http honours the cap based on Content-Length, so
// an oversized announcement short-circuits before any body bytes are
// read. Issue #78 finding M2: previously unbounded — a malicious or
// misbehaving remote could exhaust host memory.
HTTP_MAX_BODY :: 16 * 1024 * 1024 // 16 MiB

// Per-request deadline (ms). Used when the caller doesn't supply
// Http_Request.timeout_ms (or supplies <=0). The Fennel :http effect
// handler always passes a value (default 30000), so this only kicks in
// for direct Odin callers (e.g. tests). Issue #99 M1 A.
HTTP_DEFAULT_TIMEOUT_MS :: 30_000

// Cap on concurrent in-flight HTTP requests. Submissions beyond the cap
// fail synchronously with a synthesized error response. Soft cap: a
// brief race between the inflight check and the registry insert can
// allow up to N+(concurrent submitters - 1). Issue #99 M1 B.
MAX_INFLIGHT_HTTP :: 64

@(private = "file")
header_safe :: proc(s: string) -> bool {
	for r in s {
		if r == '\r' || r == '\n' || r == 0 do return false
	}
	return true
}

@(private = "file")
url_host :: proc(url: string) -> string {
	// "http://host:port/path" → "host"
	idx := strings.index(url, "://")
	if idx < 0 do return ""
	rest := url[idx + 3:]
	end := len(rest)
	for i in 0 ..< len(rest) {
		c := rest[i]
		if c == '/' || c == '?' || c == '#' { end = i; break }
	}
	host := rest[:end]
	// Strip userinfo: "user:pass@host" → "host". Last `@` since password may
	// itself be percent-encoded but cannot contain a literal `@`.
	if at := strings.last_index_byte(host, '@'); at >= 0 {
		host = host[at+1:]
	}
	// Strip IPv6 brackets if present, before stripping port.
	if strings.has_prefix(host, "[") {
		if rb := strings.index_byte(host, ']'); rb >= 0 {
			return host[1:rb]  // [::1]:8080 → ::1
		}
		return host  // malformed; return as-is
	}
	// Strip port.
	if colon := strings.last_index_byte(host, ':'); colon >= 0 {
		host = host[:colon]
	}
	return host
}

// url_port extracts the explicit port from a URL host:port, or 0 if absent.
// Mirrors url_host's parsing (userinfo + IPv6 brackets) so an authority like
// "user@[::1]:8080" yields 8080. #162 M3.
@(private = "file")
url_port :: proc(url: string) -> int {
	idx := strings.index(url, "://")
	if idx < 0 do return 0
	rest := url[idx + 3:]
	end := len(rest)
	for i in 0 ..< len(rest) {
		c := rest[i]
		if c == '/' || c == '?' || c == '#' { end = i; break }
	}
	host := rest[:end]
	if at := strings.last_index_byte(host, '@'); at >= 0 {
		host = host[at+1:]
	}
	// IPv6 literal: the port (if any) follows the closing bracket.
	if strings.has_prefix(host, "[") {
		if rb := strings.index_byte(host, ']'); rb >= 0 {
			after := host[rb+1:]
			if strings.has_prefix(after, ":") {
				if p, ok := strconv.parse_int(after[1:], 10); ok do return p
			}
			return 0
		}
		return 0
	}
	if colon := strings.last_index_byte(host, ':'); colon >= 0 {
		if p, ok := strconv.parse_int(host[colon+1:], 10); ok do return p
	}
	return 0
}

Http_Request :: struct {
	id:         string,
	url:        string,
	method:     string,
	headers:    map[string]string,
	body:       string,
	timeout_ms: int,
}

Http_Response :: struct {
	id:        string,
	status:    int,
	headers:   map[string]string,
	body:      string,
	error_msg: string,
}

@(private = "file")
Pending_Http :: struct {
	// The `id_owned` string is the same allocation as the map key for
	// this entry; freeing it once after `delete_key` releases both.
	// This is independent of the caller-supplied `req.id`, which is
	// owned by the worker's `Http_Response` and freed via
	// `http_response_destroy`. Don't try to dedupe them.
	id_owned: string,
	deadline: time.Time,
}

Http_Client :: struct {
	results:       [dynamic]Http_Response,
	results_mutex: sync.Mutex,
	pending:       map[string]Pending_Http,
	pending_mutex: sync.Mutex,
	// Set by http_client_destroy to signal in-flight workers to bail
	// without touching `results` or freeing state we'll free below.
	// Atomic so workers can check it under `sockets_mutex` between
	// dial and register without lock-ordering hazards on `pending_mutex`.
	// Issue #99 M1 B, #156.
	destroying:    bool,
	// Atomic counter of workers that have begun execute_http_request and
	// not yet completed their cleanup. Drain waits for this to reach 0
	// before tearing down so workers don't UAF the client. Distinct from
	// `len(pending)` because the timeout sweep removes pending entries
	// while the worker is still running. Issue #99 M1 B.
	workers_alive: i32,
	// Socket fds of in-flight requests, keyed by request id. Workers
	// dial via `http_client.dial`, insert here while `request_on` is
	// running, and remove on completion. `http_client_destroy`
	// force-closes any still registered to unblock workers parked in
	// `parse_response`'s blocking `net.recv_tcp`. The fork's `defer`
	// in `parse_response` frees the scanner buffer once recv returns
	// Connection_Closed. Issue #156.
	sockets:       map[string]net.TCP_Socket,
	sockets_mutex: sync.Mutex,
}

http_client_init :: proc(hc: ^Http_Client) {
}

http_client_destroy :: proc(hc: ^Http_Client) {
	// Signal workers to bail on completion. They re-check `destroying`
	// after `execute_http_request` returns and decrement `workers_alive`
	// LAST, so a worker count of 0 means no worker holds a pointer into
	// `hc`. Atomic store so the socket hook can observe shutdown
	// without locking `pending_mutex`.
	sync.atomic_store(&hc.destroying, true)

	// Phase 1: wait up to 3 s for workers to drain naturally. The
	// timeout sweep also runs here to mark long-running requests as
	// timed out; workers that complete normally during this window
	// remove themselves from `pending` and `sockets`.
	deadline := time.time_add(time.now(), 3 * time.Second)
	for {
		if sync.atomic_load(&hc.workers_alive) == 0 do break
		if time.diff(time.now(), deadline) <= 0 do break
		time.sleep(10 * time.Millisecond)

		dummy: [dynamic]Http_Response
		http_client_poll(hc, &dummy)
		for &r in dummy do http_response_destroy(&r)
		delete(dummy)
	}

	// Phase 2: force-close any sockets still registered. Workers parked
	// inside odin-http's `parse_response → net.recv_tcp` only return
	// when the socket dies, so close them ourselves. The upstream defer
	// (commits on the fork branch) frees the scanner buffer along the
	// way, eliminating the 4 KiB-per-stuck-worker leak from #156.
	sync.lock(&hc.sockets_mutex)
	for _, sock in hc.sockets {
		net.close(sock)
	}
	sync.unlock(&hc.sockets_mutex)

	// Phase 3: wait up to 1 s more for workers to unwind through the
	// now-unblocked recv. Continue sweeping timeouts so newly-failed
	// requests get cleaned up too.
	deadline2 := time.time_add(time.now(), 1 * time.Second)
	for {
		if sync.atomic_load(&hc.workers_alive) == 0 do break
		if time.diff(time.now(), deadline2) <= 0 do break
		time.sleep(10 * time.Millisecond)

		dummy: [dynamic]Http_Response
		http_client_poll(hc, &dummy)
		for &r in dummy do http_response_destroy(&r)
		delete(dummy)
	}

	leaked := sync.atomic_load(&hc.workers_alive)
	if leaked > 0 {
		fmt.eprintfln("redin: warning: %d HTTP worker(s) still in flight at shutdown", leaked)
	}

	sync.lock(&hc.results_mutex)
	for &r in hc.results do http_response_destroy(&r)
	delete(hc.results)
	sync.unlock(&hc.results_mutex)

	if leaked == 0 {
		// All workers completed their cleanup; safe to free the pending
		// and sockets maps. Any remaining sockets entries (from a worker
		// that closed normally without unregistering, in theory) own
		// nothing — the fds are already closed by `response_destroy`.
		sync.lock(&hc.pending_mutex)
		for _, entry in hc.pending do delete(entry.id_owned)
		delete(hc.pending)
		sync.unlock(&hc.pending_mutex)

		sync.lock(&hc.sockets_mutex)
		delete(hc.sockets)
		sync.unlock(&hc.sockets_mutex)
	}
	// Otherwise we deliberately leak `hc.pending` / `hc.sockets` —
	// workers may still look at them. Leaked entries leak with the
	// Http_Client.
}

http_response_destroy :: proc(r: ^Http_Response) {
	delete(r.id)
	delete(r.body)
	delete(r.error_msg)
	for k, v in r.headers {
		delete(k)
		delete(v)
	}
	delete(r.headers)
}

Http_Thread_Data :: struct {
	client:  ^Http_Client,
	request: Http_Request,
}

http_client_request :: proc(hc: ^Http_Client, req: Http_Request) {
	// In-flight cap. Soft check: two simultaneous submitters could both
	// see `inflight = 63` and both proceed, briefly reaching 65. That's
	// fine — we're enforcing a soft cap, not a hard one. Issue #99 M1 B.
	// We also peek at `destroying` under the same lock so a request issued
	// concurrently with http_client_destroy can't write into a freed
	// pending map. Production callers are main-thread only; this hardens
	// the contract for callers on other threads.
	sync.lock(&hc.pending_mutex)
	inflight := len(hc.pending)
	sync.unlock(&hc.pending_mutex)
	shutting_down := sync.atomic_load(&hc.destroying)

	if inflight >= MAX_INFLIGHT_HTTP {
		// Move req.id into the rejection response (mirrors execute_http_request,
		// which consumes req.id into response.id). http_request_destroy below
		// then frees the rest of the request's allocations.
		r := Http_Response{
			id        = req.id,
			status    = 0,
			error_msg = strings.clone("too many concurrent http requests (cap 64)"),
			headers   = make(map[string]string),
		}
		sync.lock(&hc.results_mutex)
		append(&hc.results, r)
		sync.unlock(&hc.results_mutex)
		// We own the request strings; free them since no worker will run.
		req := req
		http_request_destroy(&req)
		return
	}

	if shutting_down {
		r := Http_Response{
			id        = req.id,
			status    = 0,
			error_msg = strings.clone("http client shutting down"),
			headers   = make(map[string]string),
		}
		sync.lock(&hc.results_mutex)
		append(&hc.results, r)
		sync.unlock(&hc.results_mutex)
		req := req
		http_request_destroy(&req)
		return
	}

	timeout := req.timeout_ms <= 0 ? HTTP_DEFAULT_TIMEOUT_MS : req.timeout_ms

	// Clone req.id for the pending map. The same allocation is used as
	// both the map key and id_owned, so a single delete frees both.
	id_clone := strings.clone(req.id)
	sync.lock(&hc.pending_mutex)
	_, dup := hc.pending[id_clone]
	if !dup {
		hc.pending[id_clone] = Pending_Http{
			id_owned = id_clone,
			deadline = time.time_add(time.now(), time.Duration(timeout) * time.Millisecond),
		}
	}
	sync.unlock(&hc.pending_mutex)

	// #174: a duplicate in-flight id would overwrite the first entry's
	// map-key allocation (leak) and cause the second worker's real response
	// to be dropped (ok=false on completion). Reject synchronously instead.
	// The supported :http effect always generates unique ids; this hardens
	// the native-bridge contract where the caller supplies req.id.
	if dup {
		delete(id_clone)
		r := Http_Response {
			id        = req.id,
			status    = 0,
			error_msg = strings.clone("duplicate http request id (already in flight)"),
			headers   = make(map[string]string),
		}
		sync.lock(&hc.results_mutex)
		append(&hc.results, r)
		sync.unlock(&hc.results_mutex)
		req := req
		http_request_destroy(&req)
		return
	}

	data := new(Http_Thread_Data)
	data.client = hc
	data.request = req
	// Pass the caller's context so the worker frees strings/maps with the
	// same allocator that allocated them. Without this, the worker uses
	// `runtime.default_context()` (heap), which corrupts metadata when the
	// caller used a different allocator (e.g. the rollback stack the Odin
	// test runner installs per-test). Logger is suppressed because
	// odin-http logs Connection_Closed at log.errorf, which the test
	// runner counts as a test failure even when it's the expected
	// outcome of a slow/flaky remote.
	worker_ctx := context
	worker_ctx.logger = log.nil_logger()
	sync.atomic_add(&hc.workers_alive, 1)
	thread.create_and_start_with_data(data, http_thread_proc, init_context = worker_ctx, self_cleanup = true)
}

http_client_poll :: proc(hc: ^Http_Client, results: ^[dynamic]Http_Response) {
	now := time.now()

	// Phase 1: identify timed-out pending entries and remove them. Each
	// timed-out id_owned string is transferred to the synthesized
	// Http_Response below — do NOT clone, do NOT free here.
	timed_out_ids: [dynamic]string
	defer delete(timed_out_ids)

	sync.lock(&hc.pending_mutex)
	for _, entry in hc.pending {
		if time.diff(now, entry.deadline) <= 0 {
			append(&timed_out_ids, entry.id_owned)
		}
	}
	for id in timed_out_ids {
		delete_key(&hc.pending, id)
	}
	sync.unlock(&hc.pending_mutex)

	// Phase 2: synthesize timeout responses. Ownership of id (the
	// erstwhile id_owned) transfers into Http_Response.id; the caller's
	// http_response_destroy will delete(r.id).
	if len(timed_out_ids) > 0 {
		sync.lock(&hc.results_mutex)
		for id in timed_out_ids {
			r := Http_Response{
				id        = id,
				status    = 0,
				error_msg = strings.clone("http timeout exceeded"),
				headers   = make(map[string]string),
			}
			append(&hc.results, r)
		}
		sync.unlock(&hc.results_mutex)
	}

	// Phase 3: drain the results buffer to the caller.
	sync.lock(&hc.results_mutex)
	defer sync.unlock(&hc.results_mutex)
	for &r in hc.results {
		append(results, r)
	}
	clear(&hc.results)
}

@(private = "file")
http_thread_proc :: proc(raw_data_ptr: rawptr) {
	data := cast(^Http_Thread_Data)raw_data_ptr
	response := execute_http_request(data.request, data.client)

	sync.lock(&data.client.pending_mutex)
	if sync.atomic_load(&data.client.destroying) {
		// Client is being torn down. Don't touch results; just remove
		// our entry to allow the drain loop to make progress. Any
		// synthesized timeout response in `results` for this id has
		// already been drained by the destroy path's polling sweep;
		// nothing to clean up there.
		if entry, ok := data.client.pending[data.request.id]; ok {
			delete_key(&data.client.pending, data.request.id)
			delete(entry.id_owned)
		}
		sync.unlock(&data.client.pending_mutex)
		http_response_destroy(&response)
		http_request_destroy(&data.request)
		client := data.client
		free(data)
		// Decrement workers_alive LAST so that the drain loop doesn't
		// observe 0 and free the client while we still hold pointers
		// into it.
		sync.atomic_sub(&client.workers_alive, 1)
		return
	}

	// Re-check the registry on completion. If the entry is gone, the
	// poll loop has already synthesized a timeout result for this id —
	// drop ours on the floor. Otherwise remove our entry and surface
	// the response.
	keep := false
	if entry, ok := data.client.pending[data.request.id]; ok {
		delete_key(&data.client.pending, data.request.id)
		delete(entry.id_owned)
		keep = true
	}
	sync.unlock(&data.client.pending_mutex)

	if keep {
		sync.lock(&data.client.results_mutex)
		append(&data.client.results, response)
		sync.unlock(&data.client.results_mutex)
	} else {
		// Entry was already replaced by a timeout. Discard the result.
		http_response_destroy(&response)
	}

	http_request_destroy(&data.request)
	client := data.client
	free(data)
	sync.atomic_sub(&client.workers_alive, 1)
}

@(private = "file")
http_request_destroy :: proc(req: ^Http_Request) {
	delete(req.url)
	delete(req.method)
	delete(req.body)
	for k, v in req.headers {
		delete(k)
		delete(v)
	}
	delete(req.headers)
}

// `client` is optional. When non-nil, the request's socket is registered
// in `client.sockets` while in flight so `http_client_destroy` can
// force-close it during shutdown. Tests that drive `execute_http_request`
// synchronously (no thread, no destroy) pass nil and skip registration.
execute_http_request :: proc(req: Http_Request, client: ^Http_Client = nil) -> Http_Response {
	response: Http_Response
	response.id = req.id
	response.headers = make(map[string]string)

	// Scheme guard. Always-on; not opt-out. M4 from issue #99.
	{
		colon := strings.index_byte(req.url, ':')
		scheme := colon < 0 ? "" : strings.to_lower(req.url[:colon], context.temp_allocator)
		if scheme != "http" && scheme != "https" {
			response.status = 0
			response.error_msg = strings.clone("http scheme must be http or https")
			return response
		}
	}

	// #175: the URL's path/query is written verbatim into the request line,
	// so control bytes (CR/LF/NUL) could smuggle extra header lines or a
	// second request. header_safe is applied to header keys/values below;
	// apply it to the URL too, before dial.
	if !header_safe(req.url) {
		response.status = 0
		response.error_msg = strings.clone("http url contains invalid character")
		return response
	}

	// Whitelist + SSRF guard (#99 M4, #162 M3). Resolve the host ourselves
	// so we can enforce the access class against the *resolved* IP and then
	// dial that exact endpoint — closing the DNS-rebinding window where a
	// re-resolve between check and connect could land on a blocked address.
	parsed_url := http.url_parse(req.url)
	checked_endpoint: net.Endpoint
	{
		host := url_host(req.url)
		ep4, ep6, resolve_err := net.resolve(parsed_url.host)
		if resolve_err != nil {
			// #162 L4: don't echo the resolver error (it can confirm
			// internal names); log detail, return generic.
			fmt.eprintfln("redin: http resolve failed for %s: %v", host, resolve_err)
			response.status = 0
			response.error_msg = strings.clone("http request failed")
			return response
		}
		checked_endpoint = ep4.address != nil ? ep4 : ep6
		if !http_access_allowed(host, checked_endpoint.address) {
			response.status = 0
			response.error_msg = fmt.aprintf("host %s not in http whitelist", host)
			return response
		}
		// Fill in the port the same way odin-http's parse_endpoint would.
		checked_endpoint.port = url_port(req.url)
		if checked_endpoint.port == 0 {
			checked_endpoint.port = parsed_url.scheme == "https" ? 443 : 80
		}
	}

	method: http.Method
	lower_method := strings.to_lower(req.method)
	defer delete(lower_method)
	switch lower_method {
	case "get":
		method = .Get
	case "post":
		method = .Post
	case "put":
		method = .Put
	case "delete":
		method = .Delete
	case "patch":
		method = .Patch
	case "head":
		method = .Head
	case:
		method = .Get
	}

	http_req: http_client.Request
	http_client.request_init(&http_req, method)
	defer http_client.request_destroy(&http_req)

	for k, v in req.headers {
		if !header_safe(k) || !header_safe(v) {
			response.status = 0
			response.error_msg = strings.clone("http header contains invalid character")
			return response
		}
	}

	for k, v in req.headers {
		http.headers_set(&http_req.headers, k, v)
	}

	if len(req.body) > 0 {
		bytes.buffer_write_string(&http_req.body, req.body)
	}

	// Dial first, then register the socket so destroy can force-close
	// it. Splitting the dial out is what makes this possible — the old
	// monolithic `request()` never exposed the underlying fd. When
	// `client` is nil (sync test callers) we skip the registry dance
	// entirely.
	// Dial the endpoint we already resolved and vetted — NOT req.url, which
	// would make odin-http re-resolve and reopen the rebinding window.
	url := parsed_url
	sock, dial_err := net.dial_tcp(checked_endpoint)
	if dial_err != nil {
		// #162 L4: the raw dial error names the host/IP and the OS-level
		// reason ("connection refused on 10.0.x.x:80", "no route to
		// host"), which lets an authenticated caller map the internal
		// network one host at a time. Log the detail to stderr for the
		// developer; return a generic message to the app.
		fmt.eprintfln("redin: http dial failed for %s: %v", url_host(req.url), dial_err)
		response.status = 0
		response.error_msg = strings.clone("http request failed")
		return response
	}

	// #169: bound the socket read. The poll-side timeout in http_client_poll
	// only synthesizes a response and frees the in-flight slot; it never
	// touches the socket, so without this a worker parked in
	// request_on -> recv against a hung/tarpit peer would block (and hold
	// its fd) forever, defeating MAX_INFLIGHT_HTTP. A real receive deadline
	// makes recv return and the worker unwind.
	recv_timeout_ms := req.timeout_ms <= 0 ? HTTP_DEFAULT_TIMEOUT_MS : req.timeout_ms
	net.set_option(sock, .Receive_Timeout, time.Duration(recv_timeout_ms) * time.Millisecond)

	if client != nil {
		sync.lock(&client.sockets_mutex)
		if sync.atomic_load(&client.destroying) {
			sync.unlock(&client.sockets_mutex)
			net.close(sock)
			response.status = 0
			response.error_msg = strings.clone("http client shutting down")
			return response
		}
		client.sockets[req.id] = sock
		sync.unlock(&client.sockets_mutex)
	}

	res, req_err := http_client.request_on(&http_req, sock, url, context.allocator)

	if client != nil {
		sync.lock(&client.sockets_mutex)
		delete_key(&client.sockets, req.id)
		sync.unlock(&client.sockets_mutex)
	}

	if req_err != nil {
		// `request_on` leaves socket ownership with us on error.
		net.close(sock)
		// #162 L4: generic to the caller, detail to stderr.
		fmt.eprintfln("redin: http request failed for %s: %v", url_host(req.url), req_err)
		response.status = 0
		response.error_msg = strings.clone("http request failed")
		return response
	}
	// Success: ownership of `sock` transferred to `res`; closed by the
	// `response_destroy` call below.

	response.status = int(res.status)

	body, was_alloc, body_err := http_client.response_body(&res, HTTP_MAX_BODY)
	if body_err == .None {
		switch b in body {
		case http_client.Body_Plain:
			response.body = strings.clone(b)
		case http_client.Body_Url_Encoded:
			response.body = strings.clone("")
		case http_client.Body_Error:
		}
	} else if body_err == .Too_Long {
		response.status = 0
		response.error_msg = fmt.aprintf(
			"Response body too large (cap %d bytes)", HTTP_MAX_BODY,
		)
	} else {
		// #162 L4: generic to the caller, detail to stderr.
		fmt.eprintfln("redin: http body read failed for %s: %v", url_host(req.url), body_err)
		response.error_msg = strings.clone("http request failed")
	}

	for k, v in res.headers._kv {
		response.headers[strings.clone(k)] = strings.clone(v)
	}

	http_client.response_destroy(&res, body, was_alloc)

	return response
}
