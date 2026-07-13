package bridge

import "core:container/queue"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import rl "vendor:raylib"

// Regression tests for issue #78 finding L1: find_header_value used
// strings.index, which returns the first match anywhere in the buffer.
// If the request line contains the literal "host:" (e.g. inside a
// path or query), the first match is non-boundary, the boundary check
// fails, and the lookup returns "" without continuing past the
// poisoned occurrence — so the *real* Host header below is never seen
// and the request is rejected with 403.

@(test)
test_find_header_value_simple :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nHost: localhost:8800\r\nAuthorization: Bearer abc\r\nContent-Length: 0"
	testing.expect_value(t, find_header_value(headers, "host"), "localhost:8800")
	testing.expect_value(t, find_header_value(headers, "authorization"), "Bearer abc")
	testing.expect_value(t, find_header_value(headers, "content-length"), "0")
}

@(test)
test_find_header_value_invalid_utf8_before_host :: proc(t: ^testing.T) {
	// #164: a header value with invalid UTF-8 before Host. strings.to_lower
	// re-encodes each invalid byte as U+FFFD (1 byte -> 3), so an index
	// located in the lowercased copy no longer aligns with the original
	// `headers`, corrupting (or OOB-panicking on) the value-extraction
	// slice. This is reachable PRE-AUTH via check_host_header. The lookup
	// must stay byte-aligned and still return the real header values.
	headers := "GET / HTTP/1.1\r\nX-Junk: \xff\xfe\xc3\x28\r\nHost: localhost:8800\r\nAuthorization: Bearer abc\r\n"
	testing.expect_value(t, find_header_value(headers, "host"), "localhost:8800")
	testing.expect_value(t, find_header_value(headers, "authorization"), "Bearer abc")
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

// header_count is name-agnostic, so its count==2 / count==1 behavior is pinned
// once via Content-Length (test_header_count_detects_duplicate_content_length /
// _single, in the body section below). It backs the request parser's duplicate-
// Host / duplicate-Authorization / duplicate-Content-Length (#217 M2, #233 L2)
// and Transfer-Encoding (#233 L3) rejections; the per-name count variants were
// dropped as they re-exercised the same primitive. The request-line-anchoring
// cases (0 for a decoy alone, 1 for a decoy plus a real header) are distinct
// and kept.

@(test)
test_header_count_host_ignores_request_line :: proc(t: ^testing.T) {
	// A "host:" inside the request-line URL is not a header line.
	headers := "GET /x?host:1 HTTP/1.1\r\nHost: localhost:8800\r\n"
	testing.expect_value(t, header_count(headers, "host"), 1)
}

// #217 M2: the request body delivered to handlers was sliced as
// req_str[body_start:] — bounded by what was read into the buffer, not by the
// declared Content-Length. A recv that overshoots into the stack buffer (e.g.
// a pipelined byte) would leak trailing bytes into the "body". And a request
// with two Content-Length headers is ambiguous (request-smuggling vector);
// find_header_value only sees the first. These tests pin the body bound and
// the duplicate-header rejection.

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

// #225 L1: /frames and /agent/nodes emitted the node `tag` / `id` raw, so a
// Lua node whose tag or :id contains a `"` produced structurally broken JSON
// (and could inject an extra key an agent consumer would trust). Both must
// route through json_string.

@(test)
test_frame_tag_is_json_escaped :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// A node whose tag carries a quote + injection attempt.
	testing.expect(t, luaL_dostring(L, `return {'ev"il', {}}`) == 0, "lua build failed")

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	skips := make(map[i32]i32)
	defer delete(skips)
	dfs := 0
	frame_value_to_json(&b, L, lua_gettop(L), []rl.Rectangle{}, skips, &dfs)
	out := strings.to_string(b)

	testing.expectf(t, strings.contains(out, `\"`), "quote in tag must be escaped: %s", out)
	testing.expectf(t, strings.contains(out, `"ev\"il"`), "tag must be a single escaped string: %s", out)
	// The raw, unescaped `ev"il"` (a broken close) must not appear.
	testing.expectf(t, !strings.contains(out, `ev"il"`), "tag must not close the JSON string early: %s", out)
}

// #250 L1: /selection built its body with Odin's %q, which emits Odin escapes
// (\a for 0x07, \x00 for NUL, \xNN for invalid UTF-8) that are not valid JSON.
// selection_json now routes the text through json_string, so control bytes
// become \u00XX and the body stays strict-JSON parseable.
@(test)
test_selection_json_escapes_control_bytes :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// "a" + NUL + "b" + BEL(0x07) + "c" — the two control bytes %q would have
	// emitted as \x00 and \a.
	selection_json(&b, "text", 0, 5, "a\x00b\x07c")
	got := strings.to_string(b)

	want := `{"kind":"text","start":0,"end":5,"text":"a` + `\u0000` + `b` + `\u0007` + `c"}`
	testing.expectf(t, got == want, "got %q, want %q", got, want)
	// The invalid Odin escapes must not appear.
	testing.expectf(t, !strings.contains(got, `\a`), "must not emit Odin \\a escape: %s", got)
	testing.expectf(t, !strings.contains(got, `\x00`), "must not emit Odin \\x00 escape: %s", got)
}

// agent_nodes_walker is compiled only in REDIN_AGENT builds, so this test
// is too. Run it with: odin test src/redin/bridge ... -define:REDIN_AGENT=true
when REDIN_AGENT {
@(test)
test_agent_nodes_id_is_json_escaped :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	testing.expect(
		t,
		luaL_dostring(L, `return {'text', {agent='edit', id='a"b'}}`) == 0,
		"lua build failed",
	)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	first := true
	agent_nodes_walker(&b, L, lua_gettop(L), &first)
	out := strings.to_string(b)

	testing.expectf(t, strings.contains(out, `"id":"a\"b"`), "id quote must be escaped: %s", out)
	testing.expectf(t, strings.contains(out, `"mode":"edit"`), "mode present: %s", out)
	testing.expectf(t, strings.contains(out, `"type":"text"`), "type present: %s", out)
}
} // when REDIN_AGENT

// Tests for the dev-server handler-pool queue introduced for
// issue #129 H8. The queue is a simple sema-blocked FIFO of socket
// pointers; the acceptor pushes, handlers pop. A nil push is the
// shutdown sentinel.

@(test)
test_conn_queue_fifo :: proc(t: ^testing.T) {
	cq: Conn_Queue
	queue.init(&cq.q)
	defer queue.destroy(&cq.q)

	pc1 := new(Pending_Conn);  defer free(pc1)
	pc2 := new(Pending_Conn);  defer free(pc2)

	conn_push(&cq, pc1)
	conn_push(&cq, pc2)

	got1 := conn_pop_blocking(&cq)
	got2 := conn_pop_blocking(&cq)

	testing.expect(t, got1 == pc1, "first pop should return first push")
	testing.expect(t, got2 == pc2, "second pop should return second push")
}

@(test)
test_conn_queue_nil_sentinel :: proc(t: ^testing.T) {
	cq: Conn_Queue
	queue.init(&cq.q)
	defer queue.destroy(&cq.q)

	conn_push(&cq, nil)
	got := conn_pop_blocking(&cq)
	testing.expect(t, got == nil, "nil sentinel must round-trip")
}

@(test)
test_handler_pool_size_constant :: proc(t: ^testing.T) {
	// Pool size is part of the contract — fix the value here so an
	// accidental tweak in devserver.odin trips this test. Raised from
	// 4 → 16 in #136 M4 (slowloris mitigation).
	testing.expect_value(t, HANDLER_POOL_SIZE, 16)
}

// Mirrors the relevant half of handle_one_connection: enqueue a request,
// park on channel.done, and once woken post ack (without touching the
// channel afterward, since the drainer owns and frees it then).
@(private = "file")
Drain_Test_Ctx :: struct {
	ch:   ^Response_Channel,
	woke: bool,
}

@(private = "file")
drain_test_parked_handler :: proc(raw: rawptr) {
	c := cast(^Drain_Test_Ctx)raw
	sync.sema_wait(&c.ch.done)
	c.woke = true
	sync.sema_post(&c.ch.ack)
}

// Regression for #168: a handler that enqueued a request and parked on
// channel.done is only woken by the main render loop, which has exited at
// shutdown. drain_incoming_503 must wake every parked handler (post done +
// observe ack) so devserver_destroy's thread.join doesn't deadlock.
@(test)
test_devserver_drain_incoming_wakes_parked_handler :: proc(t: ^testing.T) {
	ds: Dev_Server
	queue.init(&ds.incoming.q)
	defer queue.destroy(&ds.incoming.q)

	ctx := Drain_Test_Ctx {
		ch = new(Response_Channel),
	}
	pending := new(Pending_Request)
	pending.method = "GET"
	pending.path = "/state"
	pending.response = ctx.ch
	sync_queue_push(&ds.incoming, pending)

	h := thread.create_and_start_with_data(&ctx, drain_test_parked_handler)

	// Blocks inside respond_* until the handler posts ack; on return the
	// channel + pending have been freed and the handler has exited.
	drain_incoming_503(&ds)

	testing.expect(t, ctx.woke, "drain_incoming_503 must wake the parked handler (#168)")
	testing.expect(t, queue.len(ds.incoming.q) == 0, "incoming queue must be empty after drain")

	if ctx.woke {
		thread.join(h)
		thread.destroy(h)
	}
}

// Regression tests for the status-line table. 409 (input-takeover /
// button-state conflicts) and 503 (acceptor overload) are emitted by
// handlers but were missing from status_text, so those error responses
// shipped with a "200 OK" status line. The default must be a loud 500,
// never a lying 200 — any future unmapped code is a server bug.

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

// Regression tests for issue #78 finding M1: the dev server's writes to
// .redin-port and .redin-token must not follow symlinks. Without
// O_NOFOLLOW, an attacker (or a stale symlink in CWD) could redirect
// the write to an arbitrary file owned by the user (e.g. ~/.ssh/authorized_keys).

@(private = "file")
make_tmp_path :: proc(suffix: string) -> string {
	dir, derr := os.temp_directory(context.temp_allocator)
	if derr != nil {
		dir = "/tmp"
	}
	pid := linux.getpid()
	return fmt.aprintf("%s/redin_test_%d_%s", dir, i32(pid), suffix)
}

@(private = "file")
read_all :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return "", false
	return string(data), true
}

@(test)
test_write_private_no_follow_creates_new_file :: proc(t: ^testing.T) {
	path := make_tmp_path("new")
	defer delete(path)
	defer os.remove(path)

	payload := "hello"
	testing.expect(t, write_private_no_follow(path, transmute([]u8)payload))

	got, ok := read_all(path)
	defer if ok do delete(got)
	testing.expect(t, ok, "expected file to be readable after write")
	testing.expect_value(t, got, payload)
}

@(test)
test_write_private_no_follow_refuses_symlink :: proc(t: ^testing.T) {
	target := make_tmp_path("symlink_target")
	link   := make_tmp_path("symlink_link")
	defer delete(target)
	defer delete(link)
	defer os.remove(target)
	defer os.remove(link)

	// Plant a regular file with sentinel content, then a symlink
	// pointing at it. If the helper follows the link, the sentinel
	// content gets overwritten — the bug under test.
	sentinel := "PROTECTED\n"
	_ = os.write_entire_file(target, transmute([]u8)sentinel)

	ctarget := strings.clone_to_cstring(target, context.temp_allocator)
	clink   := strings.clone_to_cstring(link,   context.temp_allocator)
	if errno := linux.symlink(ctarget, clink); errno != .NONE {
		testing.fail_now(t, fmt.tprintf("symlink setup failed: %v", errno))
	}

	payload := "ATTACKER_OVERWRITE"
	ok := write_private_no_follow(link, transmute([]u8)payload)
	testing.expect(t, !ok, "write_private_no_follow must refuse to write through a symlink")

	got, read_ok := read_all(target)
	defer if read_ok do delete(got)
	testing.expect(t, read_ok, "symlink target should still be readable")
	testing.expect_value(t, got, sentinel)
}

// Regression test for issue #99 finding L2: the dev server must abort
// startup if .redin-port or .redin-token cannot be written. Previously
// it logged a warning and kept running, which produced silent 401
// responses on every request because clients authenticate by reading
// .redin-token from disk.
//
// Forces a write failure by planting a directory at .redin-token in
// the test's CWD: write_private_no_follow opens with O_NOFOLLOW|O_EXCL,
// gets EEXIST, lstats and rejects anything that isn't a regular file.
@(test)
test_write_port_and_token_aborts_on_failure :: proc(t: ^testing.T) {
	original_cwd, cwd_err := os.getwd(context.temp_allocator)
	if cwd_err != nil {
		testing.fail_now(t, fmt.tprintf("getwd failed: %v", cwd_err))
	}
	defer os.chdir(original_cwd)

	tmp_dir := make_tmp_path("write_abort_dir")
	defer delete(tmp_dir)
	if mkerr := os.make_directory(tmp_dir); mkerr != nil {
		testing.fail_now(t, fmt.tprintf("make_directory(%s) failed: %v", tmp_dir, mkerr))
	}
	defer os.remove(tmp_dir)

	if cherr := os.chdir(tmp_dir); cherr != nil {
		testing.fail_now(t, fmt.tprintf("chdir(%s) failed: %v", tmp_dir, cherr))
	}

	// Plant a directory at TOKEN_FILE so write_private_no_follow refuses it.
	// PORT_FILE is left unplanted so the helper succeeds at writing it
	// first, then fails on the token write — exercising the cleanup path.
	if mkerr := os.make_directory(TOKEN_FILE); mkerr != nil {
		testing.fail_now(t, fmt.tprintf("planting directory at %s failed: %v", TOKEN_FILE, mkerr))
	}
	defer os.remove(TOKEN_FILE)
	defer os.remove(PORT_FILE) // helper writes this before failing on token

	ds := Dev_Server{
		running    = true,
		auth_token = "test_token_value",
	}

	ok := write_port_and_token_files(&ds, 9999)
	testing.expect(t, !ok, "write_port_and_token_files must return false when token write fails")
	testing.expect(t, !ds.running, "ds.running must be cleared after a write failure")

	// .redin-port must be cleaned up so it doesn't advertise a server
	// that never finished standing up.
	if _, stat_err := os.stat(PORT_FILE, context.temp_allocator); stat_err == nil {
		testing.fail(t)
		fmt.println("PORT_FILE was not cleaned up after token write failure")
	}
}

@(test)
test_write_private_no_follow_replaces_stale_regular_file :: proc(t: ^testing.T) {
	// A previous dev run that crashed leaves .redin-token behind as a
	// regular file with mode 0600. The next run must be able to replace
	// it (otherwise dev mode breaks after any crash). The replacement
	// must NOT preserve any prior content.
	path := make_tmp_path("stale")
	defer delete(path)
	defer os.remove(path)

	stale := "leftover_from_previous_run"
	_ = os.write_entire_file(path, transmute([]u8)stale)

	fresh := "new_token_value"
	testing.expect(t, write_private_no_follow(path, transmute([]u8)fresh))

	got, ok := read_all(path)
	defer if ok do delete(got)
	testing.expect(t, ok)
	testing.expect_value(t, got, fresh)
}
