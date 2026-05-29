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
	// 8 digits — exceeds the 7-digit cap.
	headers := "POST / HTTP/1.1\r\nContent-Length: 10000000\r\n"
	testing.expect(t, find_content_length(headers) < 0,
		"expected negative when digit count exceeds 7-digit cap")
}

@(test)
test_find_content_length_7_digits_ok :: proc(t: ^testing.T) {
	headers := "POST / HTTP/1.1\r\nContent-Length: 9999999\r\n"
	testing.expect_value(t, find_content_length(headers), 9999999)
}

@(test)
test_check_host_header_case_insensitive :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHost: LOCALHOST:8800\r\n"
	testing.expect(t, check_host_header(headers, "127.0.0.1:8800", "localhost:8800"),
		"expected uppercase LOCALHOST to match")
}

@(test)
test_check_host_header_v4 :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHost: 127.0.0.1:8800\r\n"
	testing.expect(t, check_host_header(headers, "127.0.0.1:8800", "localhost:8800"),
		"expected 127.0.0.1 to match")
}

@(test)
test_check_host_header_rejects_foreign :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHost: evil.com:8800\r\n"
	testing.expect(t, !check_host_header(headers, "127.0.0.1:8800", "localhost:8800"),
		"expected foreign host to be rejected")
}

@(test)
test_check_bearer_token_mixed_case :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nAuthorization: BEARER abc123\r\n"
	testing.expect(t, check_bearer_token(headers, "abc123"),
		"expected mixed-case BEARER prefix to be accepted")
}

@(test)
test_check_bearer_token_lowercase :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nAuthorization: bearer abc123\r\n"
	testing.expect(t, check_bearer_token(headers, "abc123"),
		"expected lowercase bearer prefix to be accepted")
}

@(test)
test_check_bearer_token_wrong_token :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nAuthorization: Bearer wrong\r\n"
	testing.expect(t, !check_bearer_token(headers, "abc123"),
		"expected wrong token to be rejected")
}

@(test)
test_check_bearer_token_empty_expected :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nAuthorization: Bearer anything\r\n"
	testing.expect(t, !check_bearer_token(headers, ""),
		"expected empty expected token to reject all")
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

@(test)
test_find_content_length_ignores_request_line :: proc(t: ^testing.T) {
	// #185: "content-length:" inside the request-line URL/query must not be
	// parsed as the body length (find_content_length now skips the request
	// line via find_header_value, like the #78 hardening for other headers).
	headers := "GET /state/x?content-length:9 HTTP/1.1\r\nHost: localhost:8800\r\n"
	testing.expect_value(t, find_content_length(headers), 0)
}
