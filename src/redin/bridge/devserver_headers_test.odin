package bridge

// Regression tests for issue #78 finding L1: find_header_value used
// strings.index, which returns the first match anywhere in the buffer.
// If the request line contains the literal "host:" (e.g. inside a
// path or query), the first match is non-boundary, the boundary check
// fails, and the lookup returns "" without continuing past the
// poisoned occurrence — so the *real* Host header below is never seen
// and the request is rejected with 403.

import "core:testing"

@(test)
test_find_header_value_simple :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHost: localhost:8800\r\nAuthorization: Bearer abc\r\nContent-Length: 0"
	testing.expect_value(t, find_header_value(headers, "host"), "localhost:8800")
	testing.expect_value(t, find_header_value(headers, "authorization"), "Bearer abc")
	testing.expect_value(t, find_header_value(headers, "content-length"), "0")
}

@(test)
test_find_header_value_missing :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHost: localhost:8800"
	testing.expect_value(t, find_header_value(headers, "x-not-here"), "")
}

@(test)
test_find_header_value_case_insensitive :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHOST: localhost:8800\r\nauthorization: Bearer xyz"
	testing.expect_value(t, find_header_value(headers, "host"), "localhost:8800")
	testing.expect_value(t, find_header_value(headers, "authorization"), "Bearer xyz")
}

@(test)
test_find_header_value_path_contains_host :: proc(t: ^testing.T) {
	// The request line contains "host:" inside the path. The lookup
	// must skip past it and still find the real Host header below.
	headers := "GET /state/host:foo HTTP/1.1\r\nHost: localhost:8800\r\n"
	testing.expect_value(t, find_header_value(headers, "host"), "localhost:8800")
}

@(test)
test_find_header_value_query_contains_authorization :: proc(t: ^testing.T) {
	headers := "GET /search?q=authorization:Bearer HTTP/1.1\r\nAuthorization: Bearer real-token\r\n"
	testing.expect_value(t, find_header_value(headers, "authorization"), "Bearer real-token")
}

@(test)
test_find_header_value_trims_whitespace :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHost:    localhost:8800   \r\n"
	testing.expect_value(t, find_header_value(headers, "host"), "localhost:8800")
}

@(test)
test_find_content_length_overflow_returns_negative :: proc(t: ^testing.T) {
	// 13 digits — exceeds the 12-digit cap but well within int64 range,
	// so the unpatched parser would have returned 1_000_000_000_000 (positive)
	// and slipped past MAX_BODY checks. Patched parser must return -1.
	headers := "POST / HTTP/1.1\r\nContent-Length: 1000000000000\r\n"
	testing.expect(t, find_content_length(headers) < 0,
		"expected negative when digit count exceeds 12-digit cap")
}

@(test)
test_find_content_length_normal :: proc(t: ^testing.T) {
	headers := "POST / HTTP/1.1\r\nContent-Length: 1024\r\n"
	testing.expect_value(t, find_content_length(headers), 1024)
}

@(test)
test_find_content_length_zero :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nContent-Length: 0\r\n"
	testing.expect_value(t, find_content_length(headers), 0)
}
