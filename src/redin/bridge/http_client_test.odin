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
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
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
	// We expect a generic connect failure (status 0, "http request failed"
	// per #162 L4), NOT the scheme-rejection error_msg.
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

// #162 M3: the "external" class must block a host that resolves to
// loopback. This is the core SSRF assertion — enforcement is against the
// resolved IP. No mock server: rejection happens before the dial, so there
// is nothing to connect to (a mock's accept loop would hang the test).
@(test)
test_http_access_external_blocks_loopback :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"external"})
	defer set_http_whitelist(nil)

	req := Http_Request{
		id = strings.clone("ssrf-1"),
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
	testing.expect(t, strings.contains(got.error_msg, "whitelist"),
		"expected whitelist rejection for loopback under 'external'")
}

// "local" allows loopback — the companion to the block test.
@(test)
test_http_access_local_allows_loopback :: proc(t: ^testing.T) {
	resp := "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil { testing.fail_now(t, "could not bind mock") }
	defer mock_stop(m)

	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"local"})
	defer set_http_whitelist(nil)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("ssrf-2"), url = strings.clone(url),
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

// An explicit loopback entry still allows it even under "external" — the
// explicit opt-in always wins over the class.
@(test)
test_http_access_explicit_entry_overrides_class :: proc(t: ^testing.T) {
	resp := "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil { testing.fail_now(t, "could not bind mock") }
	defer mock_stop(m)

	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	set_http_whitelist([]string{"external", "127.0.0.1"})
	defer set_http_whitelist(nil)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("ssrf-3"), url = strings.clone(url),
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
test_http_whitelist_host_trailing_dot :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	// #217 M1: DNS treats "example.com" and the fully-qualified "example.com."
	// (with the explicit root label) as the same name. A whitelist entry
	// written without the trailing dot must still match a URL host that
	// carries one — otherwise a user sees a confusing denial and is tempted
	// to widen the whitelist to work around it.
	set_http_whitelist([]string{"example.com"})
	defer set_http_whitelist(nil)

	rejected, ok := http_whitelist_check("example.com.")
	testing.expect(t, ok, "fully-qualified host should match dotless whitelist entry")
	testing.expect_value(t, rejected, "")
}

@(test)
test_http_whitelist_entry_trailing_dot :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)

	// Symmetric case: the root dot is on the whitelist entry instead of the
	// host. Normalization must strip it from both sides before comparing.
	set_http_whitelist([]string{"example.com."})
	defer set_http_whitelist(nil)

	rejected, ok := http_whitelist_check("example.com")
	testing.expect(t, ok, "dotless host should match trailing-dot whitelist entry")
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

// --- #163: malformed responses must not abort the process (negative-slice) ---

@(private = "file")
expect_no_crash_with_error :: proc(t: ^testing.T, label: string, response: string) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	m := mock_start(response)
	if m == nil do testing.fail_now(t, "could not bind a mock server port")
	defer mock_stop(m)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request {
		id     = strings.clone("neg"),
		url    = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer {
		delete(req.id)
		delete(req.url)
		delete(req.method)
	}

	// The point of the test: this call must RETURN (with an error), not
	// abort the whole process on a negative-index slice (#163).
	got := execute_http_request(req)
	defer {
		delete(got.body)
		delete(got.error_msg)
		for k, v in got.headers {delete(k);delete(v)}
		delete(got.headers)
	}

	testing.expectf(t, len(got.error_msg) > 0, "%s: expected an error, not success/crash", label)
}

@(test)
test_http_negative_content_length_no_crash :: proc(t: ^testing.T) {
	expect_no_crash_with_error(t, "negative Content-Length",
		"HTTP/1.1 200 OK\r\nContent-Length: -1\r\nConnection: close\r\n\r\nx")
}

@(test)
test_http_negative_chunk_size_no_crash :: proc(t: ^testing.T) {
	expect_no_crash_with_error(t, "negative chunk size",
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n-1\r\n")
}

@(test)
test_http_spaceless_status_line_no_crash :: proc(t: ^testing.T) {
	expect_no_crash_with_error(t, "spaceless status line",
		"HTTP/1.1200OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
}

// --- #169: a hung peer must not pin the worker past the timeout ---

@(test)
test_http_socket_timeout_unblocks_hung_peer :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	m := mock_start_slow() // accepts, reads the request, then sleeps ~2s without replying
	if m == nil do testing.fail_now(t, "could not bind a mock server port")
	defer mock_stop(m)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request {
		id         = strings.clone("slow"),
		url        = strings.clone(url),
		method     = strings.clone("GET"),
		timeout_ms = 500,
	}
	defer {
		delete(req.id)
		delete(req.url)
		delete(req.method)
	}

	// Suppress odin-http's log.error on the expected recv timeout (Would_Block),
	// mirroring the production worker (http_client_request sets nil_logger);
	// otherwise the test runner counts that error log as a failure.
	context.logger = log.nil_logger()

	start := time.now()
	got := execute_http_request(req)
	elapsed := time.diff(start, time.now())
	defer {
		delete(got.body)
		delete(got.error_msg)
		for k, v in got.headers {delete(k);delete(v)}
		delete(got.headers)
	}

	testing.expectf(t, elapsed < 1500 * time.Millisecond,
		"execute_http_request blocked %v on a non-responding peer; the 500ms socket Receive_Timeout should unblock recv (#169)",
		elapsed)
	testing.expect(t, got.status == 0, "expected a timeout error status, not success")
}
// #175: the request URL is written verbatim into the request line, so
// control bytes in the path/query could smuggle extra headers / a second
// request. header_safe is applied to header keys/values; it must apply to
// the URL too.
@(test)
test_http_url_rejects_crlf :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	req := Http_Request {
		id     = strings.clone("url-crlf"),
		url    = strings.clone("http://127.0.0.1:1/x\r\nX-Injected: 1"),
		method = strings.clone("GET"),
	}
	defer {
		delete(req.id)
		delete(req.url)
		delete(req.method)
	}

	got := execute_http_request(req)
	defer {
		delete(got.body)
		delete(got.error_msg)
		for k, v in got.headers {delete(k);delete(v)}
		delete(got.headers)
	}

	testing.expect(t, got.status == 0, "expected error status for CRLF in URL")
	testing.expectf(t, strings.contains(got.error_msg, "invalid character"),
		"expected 'invalid character' rejection before dial, got %q (#175)", got.error_msg)
}

// #174: pending/sockets are keyed by caller-supplied req.id. Two in-flight
// requests sharing an id make the second insert overwrite the first's
// map-key allocation (leak) and the second's real response gets dropped.
// http_client_request must reject a duplicate in-flight id synchronously
// instead of starting a second worker.
@(test)
test_http_duplicate_id_rejected :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	hc: Http_Client
	http_client_init(&hc)
	defer http_client_destroy(&hc)

	m := mock_start_slow() // accepts, then sleeps — keeps req1 in flight
	if m == nil do testing.fail_now(t, "could not bind a mock server port")
	defer mock_stop(m)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)

	// First request: inserts pending["dup"] synchronously, then runs.
	req1 := Http_Request {
		id     = strings.clone("dup"),
		url    = strings.clone(url),
		method = strings.clone("GET"),
	}
	http_client_request(&hc, req1)
	after_first := sync.atomic_load(&hc.workers_alive)

	// Second request with the SAME id must be rejected without a new worker.
	req2 := Http_Request {
		id     = strings.clone("dup"),
		url    = strings.clone(url),
		method = strings.clone("GET"),
	}
	http_client_request(&hc, req2)

	testing.expectf(t, sync.atomic_load(&hc.workers_alive) == after_first,
		"duplicate-id request must not start another worker (#174); workers_alive %d -> %d",
		after_first, sync.atomic_load(&hc.workers_alive))

	results: [dynamic]Http_Response
	defer delete(results)
	http_client_poll(&hc, &results)
	found := false
	for &r in results {
		if strings.contains(r.error_msg, "duplicate") do found = true
		http_response_destroy(&r)
	}
	testing.expect(t, found, "expected a 'duplicate' rejection result (#174)")
}
// #177: parse_response cloned header keys/values into res.headers, but on a
// malformed-header error return only the scanner was destroyed — the headers
// map (and the bytes cloned before the bad line) leaked, since redin's caller
// net.closes rather than response_destroy on error. A valid header followed
// by a colon-less line exercises that path.
@(test)
test_http_malformed_response_no_header_leak :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	m := mock_start("HTTP/1.1 200 OK\r\nX-Good: 1\r\nMalformedHeaderNoColon\r\n\r\n")
	if m == nil do testing.fail_now(t, "could not bind a mock server port")
	defer mock_stop(m)
	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	old := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = old
		mem.tracking_allocator_destroy(&track)
	}

	req := Http_Request {
		id     = strings.clone("hdr-leak"),
		url    = strings.clone(url),
		method = strings.clone("GET"),
	}
	got := execute_http_request(req)

	// Free everything redin owns from the (error) response. got.id aliases
	// req.id (response.id = req.id), so free it once via got.id.
	delete(req.url)
	delete(req.method)
	delete(got.id)
	delete(got.body)
	delete(got.error_msg)
	for k, v in got.headers {delete(k);delete(v)}
	delete(got.headers)

	leaks := len(track.allocation_map)
	testing.expectf(t, leaks == 0,
		"malformed response leaked %d allocation(s) — parse_response must free its partial headers (#177)",
		leaks)
}

// ---------------------------------------------------------------------------
// TLS certificate verification (vendored odin-http client).
//
// The HTTPS branch of lib/odin-http/client previously created its
// SSL_CTX with OpenSSL's default SSL_VERIFY_NONE and set no expected
// hostname, so ANY certificate — self-signed, expired, wrong host —
// was accepted silently. `redin.http` over https was MITM-able.
//
// The test drives a real `openssl s_server` with certs generated at
// test time. Three scenarios run inside ONE test proc because
// SSL_CERT_FILE is process-global state and ordering must stay
// deterministic:
//   a) no trust configured → self-signed server must be REJECTED
//   b) SSL_CERT_FILE=good  → trusted cert with matching IP SAN succeeds
//   c) SSL_CERT_FILE=bad   → trusted cert WITHOUT 127.0.0.1 in its SAN
//      must be REJECTED (hostname/IP verification)
// (SSL_CTX_set_default_verify_paths honours SSL_CERT_FILE per request,
// and the client builds a fresh SSL_CTX per request.)
//
// Requires the `openssl` CLI (present on dev machines and ubuntu CI).

@(private = "file")
TLS_TEST_DIR :: "/tmp/redin-tls-verify-test"

@(private = "file")
run_openssl :: proc(args: []string) -> bool {
	desc := os.Process_Desc {
		command = args,
	}
	process, err := os.process_start(desc)
	if err != nil do return false
	state, wait_err := os.process_wait(process)
	return wait_err == nil && state.exit_code == 0
}

// Bind port 0 on loopback to find a free port, then release it for
// s_server. (Small bind race, fine for tests.)
@(private = "file")
tls_free_port :: proc() -> int {
	s, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil do return -1
	defer net.close(s)
	ep, ep_err := net.bound_endpoint(s)
	if ep_err != nil do return -1
	return ep.port
}

// Start `openssl s_server` and wait until it accepts TCP connections.
@(private = "file")
start_tls_server :: proc(cert, key: string, port: int) -> (process: os.Process, ok: bool) {
	desc := os.Process_Desc {
		command = []string{
			"openssl", "s_server",
			"-accept", fmt.tprintf("127.0.0.1:%d", port),
			"-cert", cert, "-key", key,
			"-www", "-quiet",
		},
	}
	p, err := os.process_start(desc)
	if err != nil do return p, false
	ep := net.Endpoint{address = net.IP4_Loopback, port = port}
	for _ in 0 ..< 100 {
		s, dial_err := net.dial_tcp(ep)
		if dial_err == nil {
			net.close(s)
			return p, true
		}
		time.sleep(50 * time.Millisecond)
	}
	_ = os.process_kill(p)
	_, _ = os.process_wait(p)
	return p, false
}

@(private = "file")
stop_tls_server :: proc(process: os.Process) {
	_ = os.process_kill(process)
	_, _ = os.process_wait(process)
}

@(private = "file")
tls_get :: proc(url: string) -> Http_Response {
	req := Http_Request {
		id     = strings.clone("tls-test"),
		url    = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer {
		delete(req.id)
		delete(req.url)
		delete(req.method)
	}
	return execute_http_request(req)
}

@(private = "file")
tls_response_free :: proc(got: ^Http_Response) {
	delete(got.body)
	delete(got.error_msg)
	for k, v in got.headers {
		delete(k)
		delete(v)
	}
	delete(got.headers)
}

@(test)
test_https_verifies_certificates :: proc(t: ^testing.T) {
	sync.lock(&g_test_http_state_mutex)
	defer sync.unlock(&g_test_http_state_mutex)
	allow_open_http()
	defer set_http_whitelist(nil)

	if !os.exists(TLS_TEST_DIR) {
		if os.make_directory(TLS_TEST_DIR) != nil {
			testing.fail_now(t, "cannot create scratch dir " + TLS_TEST_DIR)
		}
	}

	good_cert :: TLS_TEST_DIR + "/good-cert.pem"
	good_key :: TLS_TEST_DIR + "/good-key.pem"
	bad_cert :: TLS_TEST_DIR + "/bad-cert.pem"
	bad_key :: TLS_TEST_DIR + "/bad-key.pem"

	// Self-signed cert whose SAN covers how the test connects.
	if !run_openssl([]string{
		"openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
		"-keyout", good_key, "-out", good_cert, "-days", "1",
		"-subj", "/CN=redin-tls-test-good",
		"-addext", "subjectAltName=IP:127.0.0.1",
	}) {
		testing.fail_now(t, "openssl req failed (good cert) — is the openssl CLI installed?")
	}
	// Self-signed cert whose SAN deliberately does NOT cover 127.0.0.1.
	if !run_openssl([]string{
		"openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
		"-keyout", bad_key, "-out", bad_cert, "-days", "1",
		"-subj", "/CN=redin-tls-test-bad",
		"-addext", "subjectAltName=DNS:wronghost.invalid",
	}) {
		testing.fail_now(t, "openssl req failed (bad cert)")
	}

	port := tls_free_port()
	if port <= 0 do testing.fail_now(t, "no free loopback port")
	server, server_ok := start_tls_server(good_cert, good_key, port)
	if !server_ok do testing.fail_now(t, "openssl s_server did not come up")

	url := fmt.aprintf("https://127.0.0.1:%d/", port)
	defer delete(url)

	// (a) No trust store configured: the self-signed cert must be
	// rejected, not silently accepted.
	got_a := tls_get(url)
	testing.expect(t, got_a.status == 0,
		fmt.tprintf("untrusted self-signed cert was ACCEPTED (status %d)", got_a.status))
	testing.expect(t, strings.contains(got_a.error_msg, "certificate"),
		fmt.tprintf("expected a certificate error, got %q", got_a.error_msg))
	tls_response_free(&got_a)

	// (b) Trusted via SSL_CERT_FILE and the IP SAN matches: succeeds.
	// Proves verification doesn't break the https happy path.
	if os.set_env("SSL_CERT_FILE", good_cert) != nil {
		stop_tls_server(server)
		testing.fail_now(t, "set_env failed")
	}
	defer _ = os.unset_env("SSL_CERT_FILE")
	got_b := tls_get(url)
	testing.expect(t, got_b.status == 200,
		fmt.tprintf("trusted matching cert should give 200, got %d (%q)",
			got_b.status, got_b.error_msg))
	tls_response_free(&got_b)
	stop_tls_server(server)

	// (c) Trusted issuer but the SAN does not cover 127.0.0.1: hostname
	// verification must reject it.
	port2 := tls_free_port()
	if port2 <= 0 do testing.fail_now(t, "no free loopback port (2)")
	server2, server2_ok := start_tls_server(bad_cert, bad_key, port2)
	if !server2_ok do testing.fail_now(t, "openssl s_server (2) did not come up")
	defer stop_tls_server(server2)
	_ = os.set_env("SSL_CERT_FILE", bad_cert)

	url2 := fmt.aprintf("https://127.0.0.1:%d/", port2)
	defer delete(url2)
	got_c := tls_get(url2)
	testing.expect(t, got_c.status == 0,
		fmt.tprintf("hostname-mismatched cert was ACCEPTED (status %d)", got_c.status))
	testing.expect(t, strings.contains(got_c.error_msg, "certificate"),
		fmt.tprintf("expected a certificate error, got %q", got_c.error_msg))
	tls_response_free(&got_c)
}
