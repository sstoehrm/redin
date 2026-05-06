package bridge

import "core:bytes"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import http "lib:odin-http"
import http_client "lib:odin-http/client"

// Cap on the response body the HTTP client is willing to allocate for a
// single request. odin-http honours the cap based on Content-Length, so
// an oversized announcement short-circuits before any body bytes are
// read. Issue #78 finding M2: previously unbounded — a malicious or
// misbehaving remote could exhaust host memory.
HTTP_MAX_BODY :: 16 * 1024 * 1024 // 16 MiB

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
	id:      string,
	url:     string,
	method:  string,
	headers: map[string]string,
	body:    string,
}

Http_Response :: struct {
	id:        string,
	status:    int,
	headers:   map[string]string,
	body:      string,
	error_msg: string,
}

Http_Client :: struct {
	results:       [dynamic]Http_Response,
	results_mutex: sync.Mutex,
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
	data := new(Http_Thread_Data)
	data.client = hc
	data.request = req
	thread.create_and_start_with_data(data, http_thread_proc, self_cleanup = true)
}

http_client_poll :: proc(hc: ^Http_Client, results: ^[dynamic]Http_Response) {
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

	sync.lock(&data.client.results_mutex)
	append(&data.client.results, response)
	sync.unlock(&data.client.results_mutex)

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
