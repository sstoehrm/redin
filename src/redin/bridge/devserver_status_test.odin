package bridge

// Regression tests for the status-line table. 409 (input-takeover /
// button-state conflicts) and 503 (acceptor overload) are emitted by
// handlers but were missing from status_text, so those error responses
// shipped with a "200 OK" status line. The default must be a loud 500,
// never a lying 200 — any future unmapped code is a server bug.

import "core:testing"

@(test)
test_status_text_conflict_and_unavailable :: proc(t: ^testing.T) {
	testing.expect_value(t, status_text(409), "409 Conflict")
	testing.expect_value(t, status_text(503), "503 Service Unavailable")
}

@(test)
test_status_text_known_codes_unchanged :: proc(t: ^testing.T) {
	testing.expect_value(t, status_text(200), "200 OK")
	testing.expect_value(t, status_text(400), "400 Bad Request")
	testing.expect_value(t, status_text(404), "404 Not Found")
}

@(test)
test_status_text_unknown_code_is_500 :: proc(t: ^testing.T) {
	testing.expect_value(t, status_text(999), "500 Internal Server Error")
	testing.expect_value(t, status_text(123), "500 Internal Server Error")
}
