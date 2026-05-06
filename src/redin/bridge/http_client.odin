package bridge

import "core:bytes"
import "core:fmt"
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
}

http_client_init :: proc(hc: ^Http_Client) {
}

http_client_destroy :: proc(hc: ^Http_Client) {
	sync.lock(&hc.results_mutex)
	for &r in hc.results {
		http_response_destroy(&r)
	}
	delete(hc.results)
	sync.unlock(&hc.results_mutex)

	// Free remaining pending entries. In-flight workers may still hold a
	// pointer to hc and try to lock pending_mutex on completion — that's
	// caller's responsibility to avoid (don't destroy while requests are
	// outstanding). For tests, the timeout sweep before destroy + the
	// 200ms test deadline ensures the pending map is empty by here.
	sync.lock(&hc.pending_mutex)
	for _, entry in hc.pending {
		delete(entry.id_owned)
	}
	delete(hc.pending)
	sync.unlock(&hc.pending_mutex)
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
	thread.create_and_start_with_data(data, http_thread_proc, self_cleanup = true)
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

	// Re-check the registry on completion. If the entry is gone, the
	// poll loop has already synthesized a timeout result for this id —
	// drop ours on the floor. Otherwise remove our entry and surface
	// the response.
	keep := false
	sync.lock(&data.client.pending_mutex)
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
	free(data)
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
