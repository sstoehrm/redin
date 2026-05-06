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

// Tests that mutate the package-level HTTP whitelist (g_http_whitelist) share
// process state. Odin's test runner runs tests in parallel by default, so a
// test that sets the whitelist can race against a separate test that issues
// an HTTP request and depends on the whitelist being unset. Acquire this
// mutex in any test that either calls set_http_whitelist or calls
// execute_http_request with a host the whitelist might reject.
@(private = "file")
g_test_http_state_mutex: sync.Mutex

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

@(private = "file")
mock_start :: proc(response: string) -> ^Mock_Server {
	m := new(Mock_Server)
	m.response = response
	for p in 18900 ..< 19000 {
		s, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = p})
		if err == nil {
			m.sock = s
			m.port = p
			break
		}
	}
	if m.port == 0 do return nil
	m.thread = thread.create_and_start_with_poly_data(m, mock_serve, context)
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
