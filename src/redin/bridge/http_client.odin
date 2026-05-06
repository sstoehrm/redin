package bridge

import "core:bytes"
import "core:fmt"
import "core:log"
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
	// Read/written under `pending_mutex`. Issue #99 M1 B.
	destroying:    bool,
	// Atomic counter of workers that have begun execute_http_request and
	// not yet completed their cleanup. Drain waits for this to reach 0
	// before tearing down so workers don't UAF the client. Distinct from
	// `len(pending)` because the timeout sweep removes pending entries
	// while the worker is still running. Issue #99 M1 B.
	workers_alive: i32,
}

http_client_init :: proc(hc: ^Http_Client) {
}

http_client_destroy :: proc(hc: ^Http_Client) {
	// Signal workers to bail on completion. They re-check `destroying`
	// under `pending_mutex` after `execute_http_request` returns and
	// decrement `workers_alive` LAST, so a worker count of 0 means no
	// worker holds a pointer into `hc`.
	sync.lock(&hc.pending_mutex)
	hc.destroying = true
	sync.unlock(&hc.pending_mutex)

	// Wait for all in-flight workers to complete their cleanup. We watch
	// `workers_alive` (atomic) rather than `len(pending)` because the
	// timeout sweep removes pending entries while the worker thread is
	// still running its HTTP I/O. Cap the wait so a stuck remote doesn't
	// hang shutdown forever.
	deadline := time.time_add(time.now(), 3 * time.Second)
	for {
		if sync.atomic_load(&hc.workers_alive) == 0 do break
		if time.diff(time.now(), deadline) <= 0 do break
		time.sleep(10 * time.Millisecond)

		// Sweep timed-out entries while we wait, so workers blocked
		// reading the response notice (their HTTP call may eventually
		// fail naturally; the sweep at least keeps the registry tidy).
		dummy: [dynamic]Http_Response
		http_client_poll(hc, &dummy)
		for &r in dummy do http_response_destroy(&r)
		delete(dummy)
	}

	// Final cleanup. Anything still alive is a worker we couldn't drain
	// — log and leak (better than UAF when the worker eventually
	// returns).
	leaked := sync.atomic_load(&hc.workers_alive)
	if leaked > 0 {
		fmt.eprintfln("redin: warning: %d HTTP worker(s) still in flight at shutdown; leaking their state", leaked)
	}

	sync.lock(&hc.results_mutex)
	for &r in hc.results do http_response_destroy(&r)
	delete(hc.results)
	sync.unlock(&hc.results_mutex)

	if leaked == 0 {
		// All workers completed their cleanup; safe to free the pending
		// map. Any remaining entries (from timeout sweep removals where
		// the worker had already decremented workers_alive) own no live
		// references at this point.
		sync.lock(&hc.pending_mutex)
		for _, entry in hc.pending do delete(entry.id_owned)
		delete(hc.pending)
		sync.unlock(&hc.pending_mutex)
	}
	// Otherwise we deliberately leak `hc.pending` — workers may still
	// look at it. Leaked entries leak with the Http_Client.
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
	sync.lock(&hc.pending_mutex)
	inflight := len(hc.pending)
	sync.unlock(&hc.pending_mutex)

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

	timeout := req.timeout_ms <= 0 ? HTTP_DEFAULT_TIMEOUT_MS : req.timeout_ms

	// Clone req.id for the pending map. The same allocation is used as
	// both the map key and id_owned, so a single delete frees both.
	id_clone := strings.clone(req.id)
	sync.lock(&hc.pending_mutex)
	hc.pending[id_clone] = Pending_Http{
		id_owned = id_clone,
		deadline = time.time_add(time.now(), time.Duration(timeout) * time.Millisecond),
	}
	sync.unlock(&hc.pending_mutex)

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
	response := execute_http_request(data.request)

	sync.lock(&data.client.pending_mutex)
	if data.client.destroying {
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

execute_http_request :: proc(req: Http_Request) -> Http_Response {
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

	// Whitelist guard. Opt-in via bridge.set_http_whitelist. M4 from issue #99.
	{
		host := url_host(req.url)
		if rejected, ok := http_whitelist_check(host); !ok {
			response.status = 0
			response.error_msg = fmt.aprintf("host %s not in http whitelist", rejected)
			return response
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

	res, err := http_client.request(&http_req, req.url)
	if err != nil {
		response.status = 0
		response.error_msg = fmt.aprintf("Request failed: %v", err)
		return response
	}

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
		response.error_msg = fmt.aprintf("Body read failed: %v", body_err)
	}

	for k, v in res.headers._kv {
		response.headers[strings.clone(k)] = strings.clone(v)
	}

	http_client.response_destroy(&res, body, was_alloc)

	return response
}
