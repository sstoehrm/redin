package bridge

// #217 M2: the request body delivered to handlers was sliced as
// req_str[body_start:] — bounded by what was read into the buffer, not by the
// declared Content-Length. A recv that overshoots into the stack buffer (e.g.
// a pipelined byte) would leak trailing bytes into the "body". And a request
// with two Content-Length headers is ambiguous (request-smuggling vector);
// find_header_value only sees the first. These tests pin the body bound and
// the duplicate-header rejection.

import "core:testing"

@(test)
test_extract_body_bounds_to_content_length :: proc(t: ^testing.T) {
	// 10 bytes follow the headers but Content-Length announces 5. The body
	// must be exactly the announced 5 bytes — the trailing "EXTRA" is not part
	// of this request and must never reach a handler.
	req := "POST /events HTTP/1.1\r\nContent-Length: 5\r\n\r\nhelloEXTRA"
	testing.expect_value(t, extract_body(req), "hello")
}

@(test)
test_extract_body_caps_at_available :: proc(t: ^testing.T) {
	// Declared 100 but only 3 bytes arrived (short read). extract_body must
	// not slice past what is actually present.
	req := "POST /x HTTP/1.1\r\nContent-Length: 100\r\n\r\nabc"
	testing.expect_value(t, extract_body(req), "abc")
}

@(test)
test_extract_body_zero_length :: proc(t: ^testing.T) {
	// Content-Length: 0 with bytes still in the buffer behind it — the classic
	// M2 repro. The body must be empty, not the smuggled bytes.
	req := "POST /events HTTP/1.1\r\nContent-Length: 0\r\n\r\n[\"x\"]"
	testing.expect_value(t, extract_body(req), "")
}

@(test)
test_extract_body_no_content_length :: proc(t: ^testing.T) {
	req := "GET /state HTTP/1.1\r\nHost: localhost:8800\r\n\r\n"
	testing.expect_value(t, extract_body(req), "")
}

@(test)
test_header_count_detects_duplicate_content_length :: proc(t: ^testing.T) {
	headers := "POST /x HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 100\r\nHost: localhost:8800"
	testing.expect_value(t, header_count(headers, "content-length"), 2)
}

@(test)
test_header_count_single :: proc(t: ^testing.T) {
	headers := "POST /x HTTP/1.1\r\nContent-Length: 5\r\nHost: localhost:8800"
	testing.expect_value(t, header_count(headers, "content-length"), 1)
}

@(test)
test_header_count_ignores_request_line :: proc(t: ^testing.T) {
	// "content-length:" in the request-line URL must not count — only real
	// header lines, anchored at a line start, do (mirrors find_header_value).
	headers := "GET /state/content-length:5 HTTP/1.1\r\nHost: localhost:8800"
	testing.expect_value(t, header_count(headers, "content-length"), 0)
}
