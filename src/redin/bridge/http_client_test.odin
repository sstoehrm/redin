package bridge

// Regression tests for issue #78 finding M2: execute_http_request
// passed no max_length to http_client.response_body, so a malicious or
// misbehaving remote could announce an arbitrary Content-Length and
// drive the host out of memory. The fix caps the body at HTTP_MAX_BODY
// and surfaces Too_Long as an explicit error.
//
// Test strategy: spin up a single-shot TCP mock server in a goroutine,
// have it answer the next connection with a response header that
// claims a Content-Length above the cap, and assert that
// execute_http_request reports an error rather than streaming the body.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Tests that mutate the package-level HTTP whitelist (g_http_whitelist) share
// process state. Odin's test runner runs tests in parallel by default, so a
// test that sets the whitelist can race against a separate test that issues
// an HTTP request and depends on the whitelist being unset. Acquire this
// mutex in any test that either calls set_http_whitelist or calls
// execute_http_request with a host the whitelist might reject.
@(private = "file")
g_test_http_state_mutex: sync.Mutex

// Deny-by-default whitelist (#136 H2) means tests that issue real HTTP
// requests without specifically testing the whitelist must opt in to
// passthrough. The sentinel "*" entry matches any host.
@(private = "file")
allow_open_http :: proc() {
	set_http_whitelist([]string{"*"})
}

@(private = "file")
Mock_Server :: struct {
	sock:     net.TCP_Socket,
	port:     int,
	response: string,
	thread:   ^thread.Thread,
	done:     sync.Sema,
}

@(private = "file")
mock_serve :: proc(m: ^Mock_Server) {
	defer sync.sema_post(&m.done)
	client, _, err := net.accept_tcp(m.sock)
	if err != nil do return
	defer net.close(client)
	// Read until the request headers end so the client doesn't see RST
	// before it consumes our response.
	buf: [4096]u8
	total := 0
	for total < len(buf) {
		n, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || n <= 0 do break
		total += n
		if strings.contains(string(buf[:total]), "\r\n\r\n") do break
	}
	net.send_tcp(client, transmute([]u8)m.response)
}

// Bind a loopback socket on an OS-assigned ephemeral port and return a
// freshly allocated Mock_Server with .sock/.port populated. Returns nil
// (and frees the allocation) if binding or endpoint lookup fails — the
// caller should treat nil as an environment-level failure (e.g. sandboxed
// loopback) and fail_now their test.
@(private = "file")
mock_bind :: proc() -> ^Mock_Server {
	m := new(Mock_Server)
	s, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil {
		free(m)
		return nil
	}
	ep, ep_err := net.bound_endpoint(s)
	if ep_err != nil {
		net.close(s)
		free(m)
		return nil
	}
	m.sock = s
	m.port = ep.port
	return m
}

@(private = "file")
mock_start :: proc(response: string) -> ^Mock_Server {
	m := mock_bind()
	if m == nil do return nil
	m.response = response
	m.thread = thread.create_and_start_with_poly_data(m, mock_serve, context)
	return m
}

// Slow variant: accept the connection, read the request, then sleep
// instead of replying. Used by timeout / in-flight-cap / drain tests.
@(private = "file")
mock_start_slow :: proc() -> ^Mock_Server {
	m := mock_bind()
	if m == nil do return nil
	m.thread = thread.create_and_start_with_poly_data(m, slow_mock_serve, context)
	return m
}

@(private = "file")
mock_stop :: proc(m: ^Mock_Server) {
	sync.sema_wait(&m.done)
	if m.thread != nil {
		thread.join(m.thread)
		thread.destroy(m.thread)
	}
	net.close(m.sock)
	free(m)
}

@(test)
test_http_response_cap_rejects_oversized_content_length :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	// Announce 32 MiB. With a HTTP_MAX_BODY cap of 16 MiB the underlying
	// scanner returns Too_Long without reading the body.
	announced := 32 * 1024 * 1024
	resp := fmt.aprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", announced)
	defer delete(resp)

	m := mock_start(resp)
	if m == nil {
		testing.fail_now(t, "could not bind a mock server port in 18900..19000")
	}
	defer mock_stop(m)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id     = strings.clone("test-1"),
		url    = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer {
		delete(req.id)
		delete(req.url)
		delete(req.method)
	}

	got := execute_http_request(req)
	// NOTE: don't call http_response_destroy — got.id is a slice-copy of
	// req.id (shared storage; pre-existing ownership quirk in the worker
	// thread path). Free only the fields execute_http_request allocated
	// exclusively for the response.
	defer {
		delete(got.body)
		delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}

	// Status must NOT reflect a successful 200; we want the body cap
	// to short-circuit the response with an explicit error message.
	testing.expect(t, got.status == 0,
		fmt.tprintf("expected status 0 (capped), got %d", got.status))
	testing.expect(t, len(got.error_msg) > 0, "expected an error message about the cap")
	testing.expect(t, strings.contains(got.error_msg, "too large"),
		fmt.tprintf("expected error_msg to mention 'too large', got %q", got.error_msg))
}

@(test)
test_http_header_value_rejects_crlf :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	headers := make(map[string]string)
	headers[strings.clone("X-Smuggle")] = strings.clone("evil\r\nHost: attacker")
	defer {
		for k, v in headers { delete(k); delete(v) }
		delete(headers)
	}

	req := Http_Request{
		id      = strings.clone("crlf-test"),
		url     = strings.clone("http://127.0.0.1:1/"),
		method  = strings.clone("GET"),
		headers = headers,
	}
	defer {
		delete(req.id); delete(req.url); delete(req.method)
	}

	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}

	testing.expect(t, got.status == 0, "expected synthesized error status 0")
	testing.expect(t, strings.contains(got.error_msg, "invalid character"),
		fmt.tprintf("expected 'invalid character' in error_msg, got %q", got.error_msg))
}

@(test)
test_http_header_key_rejects_nul :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	headers := make(map[string]string)
	headers[strings.clone("X-Bad\x00key")] = strings.clone("ok")
	defer {
		for k, v in headers { delete(k); delete(v) }
		delete(headers)
	}

	req := Http_Request{
		id      = strings.clone("nul-test"),
		url     = strings.clone("http://127.0.0.1:1/"),
		method  = strings.clone("GET"),
		headers = headers,
	}
	defer {
		delete(req.id); delete(req.url); delete(req.method)
	}

	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}

	testing.expect(t, got.status == 0, "expected synthesized error status 0")
	testing.expect(t, strings.contains(got.error_msg, "invalid character"),
		fmt.tprintf("expected 'invalid character' in error_msg, got %q", got.error_msg))
}

@(test)
test_http_redirect_not_followed :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	resp := "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil {
		testing.fail_now(t, "could not bind a mock server port")
	}
	defer mock_stop(m)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("redirect-test"),
		url = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }

	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}

	testing.expect_value(t, got.status, 302)
}

@(test)
test_http_rejects_ftp_scheme :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	req := Http_Request{
		id = strings.clone("scheme-1"),
		url = strings.clone("ftp://example.com/"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 0)
	testing.expect(t, strings.contains(got.error_msg, "scheme"),
		fmt.tprintf("expected 'scheme' in error_msg, got %q", got.error_msg))
}

@(test)
test_http_rejects_file_scheme :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	req := Http_Request{
		id = strings.clone("scheme-2"),
		url = strings.clone("file:///etc/passwd"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 0)
	testing.expect(t, strings.contains(got.error_msg, "scheme"),
		"expected scheme rejection error_msg")
}

@(test)
test_http_accepts_uppercase_https :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	// Just confirms scheme matching is case-insensitive — no real connect.
	// We expect a connect error (status 0, error_msg contains "Request failed"
	// or similar), NOT the scheme-rejection error_msg.
	req := Http_Request{
		id = strings.clone("scheme-3"),
		url = strings.clone("HTTPS://127.0.0.1:1/"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect(t, !strings.contains(got.error_msg, "scheme"),
		"HTTPS (uppercase) must not be rejected as scheme")
}

@(test)
test_http_whitelist_allows_listed_host :: proc(t: ^testing.T) {
	resp := "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil { testing.fail_now(t, "could not bind mock") }
	defer mock_stop(m)

	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"127.0.0.1"})
	defer set_http_whitelist(nil)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("wl-1"), url = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 200)
}

@(test)
test_http_whitelist_blocks_unlisted_host :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"example.com"})
	defer set_http_whitelist(nil)

	req := Http_Request{
		id = strings.clone("wl-2"),
		url = strings.clone("http://127.0.0.1:1/"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 0)
	testing.expect(t, strings.contains(got.error_msg, "127.0.0.1"),
		fmt.tprintf("expected rejected host name in error, got %q", got.error_msg))
	testing.expect(t, strings.contains(got.error_msg, "whitelist"),
		"expected 'whitelist' in error message")
}

@(test)
test_http_whitelist_hostname_case_insensitive :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"Example.COM"})
	defer set_http_whitelist(nil)

	// Direct check against the whitelist function — proves case-insensitive
	// matching without requiring DNS or a network round-trip.
	rejected, ok := http_whitelist_check("example.com")
	testing.expect(t, ok, "case-insensitive match should accept lowercased host")
	testing.expect_value(t, rejected, "")
}

@(test)
test_http_whitelist_cidr_match :: proc(t: ^testing.T) {
	resp := "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil { testing.fail_now(t, "could not bind mock") }
	defer mock_stop(m)

	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"127.0.0.0/8"})
	defer set_http_whitelist(nil)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("wl-4"), url = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 200)
}

@(test)
test_http_whitelist_ipv6_cidr_match :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"2001:db8::/32"})
	defer set_http_whitelist(nil)

	{
		rejected, ok := http_whitelist_check("2001:db8:1234::1")
		testing.expect(t, ok, "IPv6 inside the /32 should match")
		testing.expect_value(t, rejected, "")
	}
	{
		rejected, ok := http_whitelist_check("2001:db9::1")
		testing.expect(t, !ok, "IPv6 outside the /32 must not match")
		testing.expect_value(t, rejected, "2001:db9::1")
	}
}

@(private = "file")
slow_mock_serve :: proc(m: ^Mock_Server) {
	defer sync.sema_post(&m.done)
	client, _, err := net.accept_tcp(m.sock)
	if err != nil do return
	defer net.close(client)
	// Read the request, then sleep instead of responding.
	buf: [4096]u8
	total := 0
	for total < len(buf) {
		n, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || n <= 0 do break
		total += n
		if strings.contains(string(buf[:total]), "\r\n\r\n") do break
	}
	time.sleep(2 * time.Second)
}

@(test)
test_http_timeout_fires :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	m := mock_start_slow()
	if m == nil { testing.fail_now(t, "could not bind a loopback mock server") }
	defer mock_stop(m)

	hc: Http_Client
	http_client_init(&hc)
	defer http_client_destroy(&hc)

	req := Http_Request{
		id = strings.clone("timeout-1"),
		url = strings.clone(fmt.tprintf("http://127.0.0.1:%d/", m.port)),
		method = strings.clone("GET"),
		timeout_ms = 200,  // 200 ms; mock sleeps 2 s
	}
	http_client_request(&hc, req)

	// Poll for up to 1 s to pick up the timeout result.
	deadline := time.time_add(time.now(), 1 * time.Second)
	results: [dynamic]Http_Response
	defer { for &r in results do http_response_destroy(&r); delete(results) }
	for time.diff(time.now(), deadline) > 0 {
		http_client_poll(&hc, &results)
		if len(results) > 0 do break
		time.sleep(50 * time.Millisecond)
	}

	testing.expect(t, len(results) == 1, "expected one timeout result")
	if len(results) == 1 {
		testing.expect_value(t, results[0].status, 0)
		testing.expect(t, strings.contains(results[0].error_msg, "timeout"),
			fmt.tprintf("expected 'timeout' in error_msg, got %q", results[0].error_msg))
	}
}

@(test)
// Fills the in-flight cap with slow requests so the destroy path has to
// force-close every registered socket. Together with the upstream defer
// in parse_response, this exercises the full #156 fix end-to-end —
// previously this test leaked 64 × 4 KiB of scanner buffers at shutdown.
test_http_inflight_cap_rejects :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	hc: Http_Client
	http_client_init(&hc)
	defer http_client_destroy(&hc)

	// Spin up a slow mock so the requests stay in flight.
	m := mock_start_slow()
	if m == nil { testing.fail_now(t, "could not bind a loopback mock server") }
	defer mock_stop(m)

	// Submit MAX_INFLIGHT_HTTP requests + 1; the +1 must be rejected.
	for i in 0 ..< MAX_INFLIGHT_HTTP {
		req := Http_Request{
			id = strings.clone(fmt.tprintf("cap-%d", i)),
			url = strings.clone(fmt.tprintf("http://127.0.0.1:%d/", m.port)),
			method = strings.clone("GET"),
			timeout_ms = 1500,
		}
		http_client_request(&hc, req)
	}
	overflow := Http_Request{
		id = strings.clone("cap-over"),
		url = strings.clone(fmt.tprintf("http://127.0.0.1:%d/", m.port)),
		method = strings.clone("GET"),
		timeout_ms = 1500,
	}
	http_client_request(&hc, overflow)

	// Poll briefly for the rejected response.
	deadline := time.time_add(time.now(), 500 * time.Millisecond)
	results: [dynamic]Http_Response
	defer { for &r in results do http_response_destroy(&r); delete(results) }
	for time.diff(time.now(), deadline) > 0 {
		http_client_poll(&hc, &results)
		if len(results) >= 1 do break
		time.sleep(20 * time.Millisecond)
	}

	found := false
	for r in results {
		if r.id == "cap-over" && strings.contains(r.error_msg, "concurrent") {
			found = true; break
		}
	}
	testing.expect(t, found, "expected overflow request to be rejected with 'concurrent' error")
}

@(test)
test_http_destroy_drains_or_times_out :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	hc := new(Http_Client)
	http_client_init(hc)

	m := mock_start_slow()
	if m == nil { testing.fail_now(t, "could not bind a loopback mock server") }
	defer mock_stop(m)

	// Submit one request with a short timeout so the registry drains naturally.
	req := Http_Request{
		id = strings.clone("drain-1"),
		url = strings.clone(fmt.tprintf("http://127.0.0.1:%d/", m.port)),
		method = strings.clone("GET"),
		timeout_ms = 100,  // 100 ms timeout, mock sleeps 2 s
	}
	http_client_request(hc, req)

	// Wait briefly so the request enters the pending registry.
	time.sleep(50 * time.Millisecond)

	// Destroy should drain workers (workers_alive→0) within the 3-second
	// internal deadline. The worker is blocked on the slow mock for ~2 s,
	// then bails via the `destroying` path. We measure: does destroy
	// return cleanly within ~3 s, and is `hc` safe to free immediately
	// afterward (workers_alive == 0 means no worker still holds a
	// pointer)?
	start := time.now()
	http_client_destroy(hc)
	elapsed := time.diff(start, time.now())
	free(hc)

	testing.expect(t, elapsed < 4 * time.Second,
		"http_client_destroy should drain within ~3 s, not hang")
}
