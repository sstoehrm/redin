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
