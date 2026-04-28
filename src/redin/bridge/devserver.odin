package bridge

import "core:container/queue"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:math"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import "../input"
import "../profile"
import "../types"
import rl "vendor:raylib"

// --- Types ---

Pending_Request :: struct {
	method:   string,
	path:     string,
	body:     string,
	response: ^Response_Channel,
}

Response_Channel :: struct {
	status:       int,
	content_type: string,
	body:         string,
	binary:       []u8,
	done:         sync.Sema,
	ack:          sync.Sema,
}

Sync_Queue :: struct {
	q:  queue.Queue(^Pending_Request),
	mu: sync.Mutex,
}

Dev_Server :: struct {
	bridge:             ^Bridge,
	tcp_sock:           net.TCP_Socket,
	port:               int,
	auth_token:         string, // 64-char hex, required as Bearer on every non-OPTIONS request
	expected_host_v4:   string, // "127.0.0.1:<port>"
	expected_host_name: string, // "localhost:<port>"
	server_thread:      ^thread.Thread,
	incoming:           Sync_Queue,
	event_queue:        [dynamic]types.InputEvent,
	running:            bool,
	shutdown_requested: bool,
}

PORT_FILE  :: ".redin-port"
TOKEN_FILE :: ".redin-token"
PORT_BASE  :: 8800
PORT_RANGE :: 100

// Number of bytes of entropy for the auth token. 32 bytes (256 bits)
// hex-encoded yields a 64-char token.
AUTH_TOKEN_BYTES :: 32

// --- Sync queue ---

sync_queue_push :: proc(sq: ^Sync_Queue, req: ^Pending_Request) {
	sync.lock(&sq.mu)
	queue.push_back(&sq.q, req)
	sync.unlock(&sq.mu)
}

sync_queue_drain :: proc(sq: ^Sync_Queue, out: ^[dynamic]^Pending_Request) {
	sync.lock(&sq.mu)
	for queue.len(sq.q) > 0 {
		if req, ok := queue.pop_front_safe(&sq.q); ok {
			append(out, req)
		}
	}
	sync.unlock(&sq.mu)
}

// --- Init/Destroy ---

// Write `data` to `path` with mode 0600, refusing to follow symlinks
// or to open any non-regular file. Used for .redin-port and .redin-token
// — see issue #78 finding M1. Without O_NOFOLLOW, an attacker (or a
// stale symlink in CWD) could redirect the write to an arbitrary file
// owned by the user (e.g. ~/.ssh/authorized_keys).
//
// On EEXIST we lstat the path and only retry after unlinking when the
// existing entry is a regular file — handles the legitimate case where
// a previous --dev run crashed without cleaning up. Symlinks raise
// ELOOP under O_NOFOLLOW, FIFOs/sockets/devices fall through without
// retry, so neither path can be hijacked.
write_private_no_follow :: proc(path: string, data: []u8) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	flags := linux.Open_Flags{.WRONLY, .CREAT, .EXCL, .TRUNC, .NOFOLLOW, .CLOEXEC}
	mode  := linux.Mode{.IRUSR, .IWUSR}

	fd, err := linux.open(cpath, flags, mode)
	if err == .EEXIST {
		// O_NOFOLLOW + O_EXCL: symlinks surface as EEXIST rather than
		// ELOOP. lstat (NOT stat) so we inspect the entry itself, not
		// what a symlink points at.
		st: linux.Stat
		if linux.lstat(cpath, &st) != .NONE do return false
		if (transmute(u32) st.mode) & 0o170000 != 0o100000 do return false
		if linux.unlink(cpath) != .NONE do return false
		fd, err = linux.open(cpath, flags, mode)
	}
	if err != .NONE do return false
	defer linux.close(fd)

	written, werr := linux.write(fd, data)
	if werr != .NONE || written != len(data) do return false
	return true
}

devserver_init :: proc(ds: ^Dev_Server, b: ^Bridge) {
	ds.bridge = b
	ds.running = true
	queue.init(&ds.incoming.q)

	sock: net.TCP_Socket
	bound_port := 0
	last_err: net.Network_Error
	for offset in 0 ..< PORT_RANGE {
		p := PORT_BASE + offset
		s, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = p})
		if err == nil {
			sock = s
			bound_port = p
			break
		}
		last_err = err
	}
	if bound_port == 0 {
		fmt.eprintfln("Dev server listen error (tried %d-%d): %v", PORT_BASE, PORT_BASE + PORT_RANGE - 1, last_err)
		ds.running = false
		return
	}

	ds.tcp_sock = sock
	ds.port = bound_port

	// Generate a per-run auth token. Written to .redin-token with mode
	// 0600 so only the running user can read it. Required as a Bearer
	// header on every non-OPTIONS request — see should_authorize().
	{
		raw: [AUTH_TOKEN_BYTES]u8
		crypto.rand_bytes(raw[:])
		enc, _ := hex.encode(raw[:])
		ds.auth_token = string(enc)
	}

	ds.expected_host_v4   = fmt.aprintf("127.0.0.1:%d", bound_port)
	ds.expected_host_name = fmt.aprintf("localhost:%d", bound_port)

	// 0600 — owner read+write only. Previously .redin-port was 0644
	// which leaked the bound port to anyone who could list the CWD.
	// Testing helpers run as the same user, so 0600 doesn't regress
	// them.
	//
	// write_private_no_follow refuses to write through a symlink — see
	// issue #78 finding M1. If a stale symlink in CWD points at a
	// sensitive file, the dev server logs and continues without writing
	// rather than overwriting the link target.
	port_str := fmt.tprintf("%d", bound_port)
	if !write_private_no_follow(PORT_FILE, transmute([]u8)port_str) {
		fmt.eprintfln("Warning: could not write %s (refused to follow non-regular path)", PORT_FILE)
	}
	if !write_private_no_follow(TOKEN_FILE, transmute([]u8)ds.auth_token) {
		fmt.eprintfln("Warning: could not write %s (refused to follow non-regular path)", TOKEN_FILE)
	}

	ds.server_thread = thread.create_and_start_with_poly_data(ds, server_thread_proc, context)
	fmt.printfln("Dev server listening on http://localhost:%d (auth token in %s)", bound_port, TOKEN_FILE)
}

devserver_destroy :: proc(ds: ^Dev_Server) {
	if ds.running {
		ds.running = false
		// Connect to unblock the accept call
		if unblock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = ds.port}); err == nil {
			net.close(unblock)
		}
		if ds.server_thread != nil {
			thread.join(ds.server_thread)
			thread.destroy(ds.server_thread)
		}
		net.close(ds.tcp_sock)
		os.remove(PORT_FILE)
		os.remove(TOKEN_FILE)
	}
	if len(ds.auth_token) > 0 do delete(ds.auth_token)
	if len(ds.expected_host_v4) > 0 do delete(ds.expected_host_v4)
	if len(ds.expected_host_name) > 0 do delete(ds.expected_host_name)
	queue.destroy(&ds.incoming.q)
	delete(ds.event_queue)
}

devserver_drain_events :: proc(ds: ^Dev_Server, events: ^[dynamic]types.InputEvent) {
	for &event in ds.event_queue {
		append(events, event)
	}
	clear(&ds.event_queue)
}

// --- Simple blocking HTTP server thread ---

// Per-recv deadline. Slowloris variant "connect and send nothing"
// unblocks via SO_RCVTIMEO when recv returns after this. Value kept
// generous enough to not trip up a sluggish local client.
CLIENT_RECV_TIMEOUT :: 5 * time.Second

// Total time any one request may take from accept to end-of-body,
// regardless of per-recv progress. Defends against drip-feed
// slowloris where a client sends one byte every CLIENT_RECV_TIMEOUT
// just often enough to keep the per-recv timer from firing.
CLIENT_REQUEST_DEADLINE :: 30 * time.Second

server_thread_proc :: proc(ds: ^Dev_Server) {
	stack_buf: [8192]u8
	MAX_BODY :: 1024 * 1024

	for ds.running {
		client, _, accept_err := net.accept_tcp(ds.tcp_sock)
		if accept_err != nil || !ds.running {
			break
		}

		// Receive timeout on this client: each recv returns within
		// CLIENT_RECV_TIMEOUT even if the peer sends nothing, so
		// "open TCP and stall" no longer pins the server thread.
		// Ignore errors — a missing timeout isn't fatal, it just
		// means we fall back to the per-request deadline below.
		_ = net.set_option(client, .Receive_Timeout, CLIENT_RECV_TIMEOUT)

		deadline := time.time_add(time.now(), CLIENT_REQUEST_DEADLINE)

		buf: []u8 = stack_buf[:]
		heap_buf: []u8
		defer if heap_buf != nil do delete(heap_buf)

		// Read full request into buffer
		total := 0
		too_large := false
		timed_out := false
		for {
			if time.diff(time.now(), deadline) < 0 {
				timed_out = true
				break
			}
			n, recv_err := net.recv_tcp(client, buf[total:])
			if recv_err != nil || n <= 0 {
				break
			}
			total += n
			// Check for end of headers (double CRLF)
			if total >= 4 {
				req_str := string(buf[:total])
				if header_end := strings.index(req_str, "\r\n\r\n"); header_end >= 0 {
					// Check Content-Length for body
					cl := find_content_length(req_str[:header_end])
					body_start := header_end + 4
					if cl > MAX_BODY {
						too_large = true
						break
					}
					needed := body_start + cl
					if needed > len(buf) {
						heap_buf = make([]u8, needed)
						copy(heap_buf, buf[:total])
						buf = heap_buf
					}
					for total < needed {
						if time.diff(time.now(), deadline) < 0 {
							timed_out = true
							break
						}
						n2, err2 := net.recv_tcp(client, buf[total:])
						if err2 != nil || n2 <= 0 do break
						total += n2
					}
					break
				}
			}
			if total >= len(buf) {
				// Headers did not fit in the stack buffer
				too_large = true
				break
			}
		}

		if timed_out {
			// 408 instead of 413/200: the client didn't finish in time.
			// Some stacks surface this to the user; for slowloris we
			// mostly care that the server thread is freed.
			resp := "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			net.send_tcp(client, transmute([]u8)resp)
			net.close(client)
			continue
		}

		if too_large {
			resp := "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			net.send_tcp(client, transmute([]u8)resp)
			net.close(client)
			continue
		}

		if total == 0 {
			net.close(client)
			continue
		}

		req_str := string(buf[:total])

		// Parse request line
		rline_end := strings.index(req_str, "\r\n")
		if rline_end < 0 {
			net.close(client)
			continue
		}
		rline := req_str[:rline_end]

		// Split request line manually (avoid allocator)
		method, path: string
		{
			sp1 := strings.index_byte(rline, ' ')
			if sp1 < 0 {
				net.close(client)
				continue
			}
			method = rline[:sp1]
			rest := rline[sp1 + 1:]
			sp2 := strings.index_byte(rest, ' ')
			path = rest[:sp2] if sp2 >= 0 else rest
		}

		// Split headers / body. Headers are everything up to the first
		// "\r\n\r\n" — the request line is included, which is fine:
		// header lookup works with any leading line, and the second
		// line onward are real headers.
		headers := req_str
		body := ""
		if header_end := strings.index(req_str, "\r\n\r\n"); header_end >= 0 {
			headers = req_str[:header_end]
			body_start := header_end + 4
			if body_start < total {
				body = req_str[body_start:]
			}
		}

		// DNS-rebinding defence: require Host: localhost:<port> or
		// 127.0.0.1:<port>. A malicious site resolving an attacker
		// hostname to 127.0.0.1 would send a different Host header,
		// so the request is rejected before the auth check runs.
		host_ok := check_host_header(headers, ds.expected_host_v4, ds.expected_host_name)
		if !host_ok {
			deny := "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			net.send_tcp(client, transmute([]u8)deny)
			net.close(client)
			continue
		}

		// OPTIONS: reject — we don't serve CORS preflight. With auth
		// required and no Access-Control-Allow-Origin emitted, browsers
		// can't make cross-origin calls regardless, so OPTIONS has no
		// legitimate use here.
		if method == "OPTIONS" {
			deny := "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			net.send_tcp(client, transmute([]u8)deny)
			net.close(client)
			continue
		}

		// Require a matching Bearer token on every non-OPTIONS request.
		if !check_bearer_token(headers, ds.auth_token) {
			deny := "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			net.send_tcp(client, transmute([]u8)deny)
			net.close(client)
			continue
		}

		// Dispatch to main thread
		channel: Response_Channel
		pending := new(Pending_Request)
		pending.method = method
		pending.path = path
		pending.body = body
		pending.response = &channel

		sync_queue_push(&ds.incoming, pending)
		sync.sema_wait(&channel.done)

		// Build and send HTTP response
		status_line := status_text(channel.status)
		ct := channel.content_type if len(channel.content_type) > 0 else "application/json"
		resp_body := channel.body if len(channel.body) > 0 else ""
		body_len := len(channel.binary) if len(channel.binary) > 0 else len(resp_body)

		// Send header line by line (no allocator needed)
		send_str(client, "HTTP/1.1 ")
		send_str(client, status_line)
		send_str(client, "\r\nContent-Type: ")
		send_str(client, ct)
		send_str(client, "\r\nContent-Length: ")
		{
			int_buf: [20]u8
			send_str(client, int_to_str(int_buf[:], body_len))
		}
		send_str(client, "\r\nConnection: close\r\n\r\n")

		if len(channel.binary) > 0 {
			net.send_tcp(client, channel.binary)
		} else {
			send_str(client, resp_body)
		}

		net.close(client)
		sync.sema_post(&channel.ack)
		free(pending)
	}
}

send_str :: proc(sock: net.TCP_Socket, s: string) {
	if len(s) > 0 {
		net.send_tcp(sock, transmute([]u8)s)
	}
}

int_to_str :: proc(buf: []u8, val: int) -> string {
	if val == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	i := len(buf)
	v := val
	for v > 0 {
		i -= 1
		buf[i] = u8(v % 10) + '0'
		v /= 10
	}
	return string(buf[i:])
}

// Case-insensitive lookup for a header value. Returns the trimmed
// value, or "" if the header is absent.
//
// Skips past the request line (everything up to the first \r\n) so a
// path/query containing the literal "host:" or "authorization:" can
// never be mistaken for a header. Issue #78 finding L1: previously the
// first non-boundary match short-circuited the lookup with "", which
// turned benign URLs like /state/host:foo into spurious 403s and
// could be turned into a Host/auth bypass by a future refactor.
find_header_value :: proc(headers: string, name_lower: string) -> string {
	lower := strings.to_lower(headers, context.temp_allocator)
	needle := strings.concatenate({name_lower, ":"}, context.temp_allocator)

	start := 0
	if rl_end := strings.index(lower, "\r\n"); rl_end >= 0 {
		start = rl_end + 2
	}

	pos := start
	for pos < len(lower) {
		rel := strings.index(lower[pos:], needle)
		if rel < 0 do return ""
		idx := pos + rel
		if idx == start || lower[idx - 1] == '\n' {
			rest := headers[idx + len(needle):]
			end := strings.index_any(rest, "\r\n")
			if end < 0 do end = len(rest)
			return strings.trim_space(rest[:end])
		}
		pos = idx + len(needle)
	}
	return ""
}

// Verify the request's Host header matches one of the expected bound
// values. Blocks DNS-rebinding attacks where a remote attacker has
// their hostname resolve to 127.0.0.1.
check_host_header :: proc(headers: string, expected_v4: string, expected_name: string) -> bool {
	host := find_header_value(headers, "host")
	if len(host) == 0 do return false
	return host == expected_v4 || host == expected_name
}

// Constant-time compare of the Authorization bearer token against
// the per-run secret. Returns true on exact match.
check_bearer_token :: proc(headers: string, expected: string) -> bool {
	if len(expected) == 0 do return false
	auth := find_header_value(headers, "authorization")
	prefix := "Bearer "
	if !strings.has_prefix(auth, prefix) {
		// Tolerate lowercase prefix (some clients).
		if !strings.has_prefix(auth, "bearer ") do return false
	}
	got := auth[len(prefix):]
	return constant_time_eq(got, expected)
}

// Length-independent equality check to avoid leaking token length via
// timing. For 64-char hex this is overkill, but trivial to get right.
@(private)
constant_time_eq :: proc(a: string, b: string) -> bool {
	if len(a) != len(b) do return false
	diff: u8 = 0
	for i in 0 ..< len(a) {
		diff |= a[i] ~ b[i]
	}
	return diff == 0
}

find_content_length :: proc(headers: string) -> int {
	lower := strings.to_lower(headers, context.temp_allocator)
	idx := strings.index(lower, "content-length:")
	if idx < 0 do return 0
	// Trim from `lower` (same index) so lookup and extraction don't
	// reference different case representations of the header block.
	rest := strings.trim_left_space(lower[idx + len("content-length:"):])
	end := strings.index_any(rest, "\r\n")
	if end < 0 do end = len(rest)
	val := strings.trim_space(rest[:end])
	n := 0
	for c in val {
		if c >= '0' && c <= '9' {
			n = n * 10 + int(c - '0')
		} else {
			break
		}
	}
	return n
}

status_text :: proc(code: int) -> string {
	switch code {
	case 200: return "200 OK"
	case 204: return "204 No Content"
	case 400: return "400 Bad Request"
	case 401: return "401 Unauthorized"
	case 403: return "403 Forbidden"
	case 404: return "404 Not Found"
	case 405: return "405 Method Not Allowed"
	case 408: return "408 Request Timeout"
	case 500: return "500 Internal Server Error"
	case:     return "200 OK"
	}
}

// --- Main loop processing ---

devserver_poll :: proc(ds: ^Dev_Server) {
	if !ds.running do return
	requests: [dynamic]^Pending_Request
	defer delete(requests)
	sync_queue_drain(&ds.incoming, &requests)
	for req in requests {
		process_request(ds, req)
	}
}

process_request :: proc(ds: ^Dev_Server, req: ^Pending_Request) {
	ch := req.response
	switch req.method {
	case "GET":
		if req.path == "/frames" {
			handle_get_frames(ds, ch)
		} else if req.path == "/state" {
			handle_get_state(ds, ch)
		} else if strings.has_prefix(req.path, "/state/") {
			handle_get_state_path(ds, ch, req.path[len("/state/"):])
		} else if req.path == "/aspects" {
			handle_get_aspects(ds, ch)
		} else if req.path == "/selection" {
			handle_get_selection(ds, ch)
		} else if req.path == "/profile" {
			handle_get_profile(ch)
		} else if req.path == "/screenshot" {
			handle_screenshot(ch)
		} else if req.path == "/window" {
			handle_get_window(ch)
		} else if req.path == "/drag-state" {
			handle_get_drag_state(ch)
		} else {
			respond_text(ch, 404, "Not found")
		}
	case "POST":
		if req.path == "/events" {
			handle_post_events(ds, ch, req.body)
		} else if req.path == "/click" {
			handle_post_click(ds, ch, req.body)
		} else if req.path == "/shutdown" {
			ds.shutdown_requested = true
			respond_json_ok(ch)
		} else if req.path == "/resize" {
			handle_post_resize(ds, ch, req.body)
		} else if req.path == "/maximize" {
			rl.MaximizeWindow()
			respond_json_ok(ch)
		} else if req.path == "/restore" {
			rl.RestoreWindow()
			respond_json_ok(ch)
		} else if req.path == "/input/mouse-down" {
			handle_post_mouse_down(ds, ch, req.body)
		} else if req.path == "/input/mouse-move" {
			handle_post_mouse_move(ds, ch, req.body)
		} else if req.path == "/input/mouse-up" {
			handle_post_mouse_up(ds, ch, req.body)
		} else if req.path == "/input/key" {
			handle_post_key(ds, ch, req.body)
		} else {
			respond_text(ch, 404, "Not found")
		}
	case "PUT":
		if req.path == "/aspects" {
			handle_put_aspects(ds, ch, req.body)
		} else {
			respond_text(ch, 404, "Not found")
		}
	case:
		respond_text(ch, 405, "Method not allowed")
	}
}

// --- Response helpers ---

respond_json :: proc(ch: ^Response_Channel, body: string) {
	ch.status = 200
	ch.content_type = "application/json"
	ch.body = body
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_json_ok :: proc(ch: ^Response_Channel) {
	ch.status = 200
	ch.content_type = "application/json"
	ch.body = `{"ok":true}`
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_json_error :: proc(ch: ^Response_Channel, status: int, msg: string) {
	ch.status = status
	ch.content_type = "application/json"
	ch.body = msg
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_text :: proc(ch: ^Response_Channel, status: int, body: string) {
	ch.status = status
	ch.content_type = "text/plain"
	ch.body = body
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_binary :: proc(ch: ^Response_Channel, content_type: string, data: []u8) {
	ch.status = 200
	ch.content_type = content_type
	ch.binary = data
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

// --- GET handlers ---

handle_get_frames :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	L := ds.bridge.L
	lua_getglobal(L, "require")
	lua_pushstring(L, "view")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	lua_getfield(L, -1, "get-last-push")
	lua_remove(L, -2)
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	lua_value_to_json(&b, L, -1)
	lua_pop(L, 1)
	respond_json(ch, strings.to_string(b))
}

handle_get_state :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	L := ds.bridge.L
	lua_getglobal(L, "redin_get_state")
	if !lua_isnil(L, -1) {
		if lua_pcall(L, 0, 1, 0) == 0 {
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			lua_value_to_json(&b, L, -1)
			lua_pop(L, 1)
			respond_json(ch, strings.to_string(b))
		} else {
			lua_pop(L, 1)
			respond_json_error(ch, 500, `{"error":"lua error"}`)
		}
	} else {
		lua_pop(L, 1)
		respond_json(ch, "{}")
	}
}

handle_get_state_path :: proc(ds: ^Dev_Server, ch: ^Response_Channel, dot_path: string) {
	L := ds.bridge.L
	lua_getglobal(L, "redin_get_state")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		respond_json(ch, "null")
		return
	}
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	// Cap segments and use rawget to skip any __index metamethods —
	// an app that sets __index on a state table could otherwise be
	// coaxed into executing Lua via crafted URL paths.
	MAX_PATH_SEGMENTS :: 32
	segments := strings.split(dot_path, ".")
	defer delete(segments)
	if len(segments) > MAX_PATH_SEGMENTS {
		lua_pop(L, 1)
		respond_json_error(ch, 400, `{"error":"path too deep"}`)
		return
	}
	for seg in segments {
		if lua_istable(L, -1) {
			lua_pushlstring(L, cstring(raw_data(seg)), uint(len(seg)))
			lua_rawget(L, -2)
			lua_remove(L, -2)
		} else {
			lua_pop(L, 1)
			lua_pushnil(L)
			break
		}
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	lua_value_to_json(&b, L, -1)
	lua_pop(L, 1)
	respond_json(ch, strings.to_string(b))
}

handle_get_aspects :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	json_begin_object(&b)
	first := true
	for name, t in ds.bridge.theme {
		if !first do json_comma(&b)
		first = false
		json_key(&b, name)
		theme_to_json(&b, t)
	}
	json_end_object(&b)
	respond_json(ch, strings.to_string(b))
}

handle_get_profile :: proc(ch: ^Response_Channel) {
	if !profile.is_enabled() {
		respond_text(ch, 404, "profile not enabled")
		return
	}

	samples := make([dynamic]profile.FrameSample, context.temp_allocator)
	profile.snapshot_into(&samples)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprintf(&b, `{{"enabled":true,"frame_cap":%d,"count":%d,`,
		profile.FRAME_CAP, len(samples))

	// phases[]
	strings.write_string(&b, `"phases":[`)
	first := true
	for phase in profile.Phase {
		if !first do strings.write_string(&b, ",")
		first = false
		fmt.sbprintf(&b, `"%s"`, profile.phase_name(phase))
	}
	strings.write_string(&b, `],`)

	// frames[]
	strings.write_string(&b, `"frames":[`)
	for s, i in samples {
		if i > 0 do strings.write_string(&b, ",")
		total_us := s.total_ns / 1000
		fmt.sbprintf(&b, `{{"idx":%d,"total_us":%d,"phase_us":[`,
			s.frame_idx, total_us)
		pfirst := true
		for phase in profile.Phase {
			if !pfirst do strings.write_string(&b, ",")
			pfirst = false
			fmt.sbprintf(&b, "%d", s.phase_ns[phase] / 1000)
		}
		strings.write_string(&b, `]}`)
	}
	strings.write_string(&b, `]}`)

	respond_json(ch, strings.to_string(b))
}

handle_get_selection :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	if !input.has_selection() || input.state.selection_kind == .None {
		fmt.sbprintf(&b, `{{"kind":"none"}}`)
		respond_json(ch, strings.to_string(b))
		return
	}

	lo, hi := input.selection_range()

	switch input.state.selection_kind {
	case .None:
		fmt.sbprintf(&b, `{{"kind":"none"}}`)

	case .Input:
		// Read buffer from state.text (UTF-8 bytes).
		content := string(input.state.text[:])
		clamped_hi := hi
		if clamped_hi > len(content) do clamped_hi = len(content)
		sub := ""
		if lo < clamped_hi do sub = content[lo:clamped_hi]
		fmt.sbprintf(&b,
			`{{"kind":"input","start":%d,"end":%d,"text":%q}}`,
			lo, clamped_hi, sub,
		)

	case .Text:
		// Resolve the selected path back to a NodeText.
		idx := input.find_node_by_path(ds.bridge.paths[:], input.state.selection_path[:])
		content := ""
		if idx >= 0 && idx < len(ds.bridge.nodes) {
			if tn, ok := ds.bridge.nodes[idx].(types.NodeText); ok do content = tn.content
		}
		clamped_hi := hi
		if clamped_hi > len(content) do clamped_hi = len(content)
		sub := ""
		if lo < clamped_hi do sub = content[lo:clamped_hi]
		fmt.sbprintf(&b,
			`{{"kind":"text","start":%d,"end":%d,"text":%q}}`,
			lo, clamped_hi, sub,
		)
	}

	respond_json(ch, strings.to_string(b))
}

theme_to_json :: proc(b: ^strings.Builder, t: types.Theme) {
	json_begin_object(b)
	first := true
	if t.bg != {} {
		if !first do json_comma(b)
		first = false
		json_key(b, "bg")
		json_begin_array(b)
		json_int(b, i64(t.bg[0]));json_comma(b)
		json_int(b, i64(t.bg[1]));json_comma(b)
		json_int(b, i64(t.bg[2]))
		json_end_array(b)
	}
	if t.color != {} {
		if !first do json_comma(b)
		first = false
		json_key(b, "color")
		json_begin_array(b)
		json_int(b, i64(t.color[0]));json_comma(b)
		json_int(b, i64(t.color[1]));json_comma(b)
		json_int(b, i64(t.color[2]))
		json_end_array(b)
	}
	if t.border != {} {
		if !first do json_comma(b)
		first = false
		json_key(b, "border")
		json_begin_array(b)
		json_int(b, i64(t.border[0]));json_comma(b)
		json_int(b, i64(t.border[1]));json_comma(b)
		json_int(b, i64(t.border[2]))
		json_end_array(b)
	}
	if t.font_size > 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "font-size");json_number(b, f64(t.font_size))
	}
	if len(t.font) > 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "font");json_string(b, t.font)
	}
	if t.radius > 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "radius");json_int(b, i64(t.radius))
	}
	if t.border_width > 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "border-width");json_int(b, i64(t.border_width))
	}
	if t.padding != {} {
		if !first do json_comma(b)
		first = false
		json_key(b, "padding")
		json_begin_array(b)
		json_int(b, i64(t.padding[0]));json_comma(b)
		json_int(b, i64(t.padding[1]));json_comma(b)
		json_int(b, i64(t.padding[2]));json_comma(b)
		json_int(b, i64(t.padding[3]))
		json_end_array(b)
	}
	if t.weight != 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "weight")
		json_string(b, t.weight == 1 ? "bold" : "italic")
	}
	if t.opacity > 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "opacity");json_number(b, f64(t.opacity))
	}
	if t.line_height > 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "line-height");json_number(b, f64(t.line_height))
	}
	if t.shadow.color[3] > 0 {
		if !first do json_comma(b)
		first = false
		json_key(b, "shadow")
		json_begin_array(b)
		json_number(b, f64(t.shadow.x));json_comma(b)
		json_number(b, f64(t.shadow.y));json_comma(b)
		json_number(b, f64(t.shadow.blur));json_comma(b)
		json_begin_array(b)
		json_int(b, i64(t.shadow.color[0]));json_comma(b)
		json_int(b, i64(t.shadow.color[1]));json_comma(b)
		json_int(b, i64(t.shadow.color[2]));json_comma(b)
		json_int(b, i64(t.shadow.color[3]))
		json_end_array(b)
		json_end_array(b)
	}
	json_end_object(b)
}

// --- POST handlers ---

handle_post_events :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	L := ds.bridge.L
	lua_getglobal(L, "redin_events")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"no event handler"}`)
		return
	}
	pos := 0
	if !json_decode_value(L, body, &pos) {
		lua_pop(L, 1)
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	lua_createtable(L, 1, 0)
	lua_pushvalue(L, -2)
	lua_rawseti(L, -2, 1)
	lua_remove(L, -2)
	if lua_pcall(L, 1, 0, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Event dispatch error: %s", msg)
		lua_pop(L, 1)
	}
	respond_json_ok(ch)
}

handle_post_click :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	// Issue #78 finding L2: previously this enqueued any (x,y) the
	// client sent, including NaN, Infinity, negative, and screen-out-of-
	// bounds values. /resize already validates and returns 400 on bad
	// input — /click now follows the same pattern.
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return
	}
	lua_getfield(L, -1, "x")
	x := f32(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_getfield(L, -1, "y")
	y := f32(lua_tonumber(L, -1))
	lua_pop(L, 1)

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	if math.is_nan(x) || math.is_nan(y) || math.is_inf(x) || math.is_inf(y) ||
	   x < 0 || y < 0 || x > sw || y > sh {
		respond_json_error(ch, 400, `{"error":"x,y out of range"}`)
		return
	}
	append(&ds.event_queue, types.InputEvent(types.MouseEvent{x = x, y = y, button = .LEFT}))
	respond_json_ok(ch)
}

handle_get_window :: proc(ch: ^Response_Channel) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, `{{"width":%d,"height":%d}}`, rl.GetScreenWidth(), rl.GetScreenHeight())
	respond_json(ch, strings.to_string(b))
}

handle_post_resize :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	// Proper JSON decode. The previous `strings.index(body, "\"width\"")`
	// approach parsed `{"widthless":999,"width":150}` as width=999 —
	// still bounded by the 100..8192 clamp, but fragile enough that a
	// future caller could be surprised.
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return
	}

	// lua_rawget reads its key from top-of-stack; after push the table
	// shifts to -2, so take the absolute index of the table first.
	table_idx := lua_gettop(L)
	read_int :: proc(L: ^Lua_State, table_idx: i32, key: string) -> int {
		lua_pushlstring(L, cstring(raw_data(key)), uint(len(key)))
		lua_rawget(L, table_idx)
		defer lua_pop(L, 1)
		return int(lua_tonumber(L, -1))
	}

	width := read_int(L, table_idx, "width")
	height := read_int(L, table_idx, "height")
	if width < 100 || height < 100 || width > 8192 || height > 8192 {
		respond_json_error(ch, 400, `{"error":"width and height must be in [100, 8192]"}`)
		return
	}
	rl.SetWindowSize(i32(width), i32(height))
	respond_json_ok(ch)
}

// --- PUT handlers ---

handle_put_aspects :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	L := ds.bridge.L
	lua_getglobal(L, "require")
	lua_pushstring(L, "theme")
	if lua_pcall(L, 1, 1, 0) == 0 {
		lua_getfield(L, -1, "set-theme")
		lua_remove(L, -2)
		pos := 0
		if json_decode_value(L, body, &pos) {
			if lua_pcall(L, 1, 0, 0) != 0 {
				lua_pop(L, 1)
			}
		} else {
			lua_pop(L, 1)
		}
	} else {
		lua_pop(L, 1)
	}
	respond_json_ok(ch)
}

// --- Drag state GET ---

handle_get_drag_state :: proc(ch: ^Response_Channel) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	switch s in input.drag {
	case input.Drag_Idle:
		strings.write_string(&b, `{"state":"idle"}`)

	case input.Drag_Pending:
		// Build src_tags JSON array.
		tags_str := drag_tags_to_json(s.src_tags)
		defer delete(tags_str)
		src_mode_str := drag_mode_string(s.src_mode)
		src_event_json := fmt.tprintf("%q", s.src_event)
		fmt.sbprintf(&b,
			`{{"state":"pending","src_idx":%d,"over_drop_idx":null,"over_zone_idx":null,"src_tags":%s,"src_event":%s,"src_mode":"%s"}}`,
			s.src_idx, tags_str, src_event_json, src_mode_str,
		)

	case input.Drag_Active:
		tags_str := drag_tags_to_json(s.src_tags)
		defer delete(tags_str)
		src_mode_str := drag_mode_string(s.src_mode)
		src_event_json := fmt.tprintf("%q", s.src_event)
		over_drop: string
		over_zone: string
		if s.over_drop_idx < 0 {
			over_drop = "null"
		} else {
			over_drop = fmt.tprintf("%d", s.over_drop_idx)
		}
		if s.over_zone_idx < 0 {
			over_zone = "null"
		} else {
			over_zone = fmt.tprintf("%d", s.over_zone_idx)
		}
		fmt.sbprintf(&b,
			`{{"state":"active","src_idx":%d,"over_drop_idx":%s,"over_zone_idx":%s,"src_tags":%s,"src_event":%s,"src_mode":"%s"}}`,
			s.src_idx, over_drop, over_zone, tags_str, src_event_json, src_mode_str,
		)

	case:
		// Nil union state (should not happen in practice).
		strings.write_string(&b, `{"state":"idle"}`)
	}

	respond_json(ch, strings.to_string(b))
}

@(private)
drag_tags_to_json :: proc(tags: []string) -> string {
	if tags == nil || len(tags) == 0 do return "null"
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for tag, i in tags {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%q", tag)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private)
drag_mode_string :: proc(mode: types.Drag_Mode) -> string {
	switch mode {
	case .Preview: return "preview"
	case .None:    return "none"
	}
	return "none"
}

// --- Input override helpers ---

// Parse {x, y} from JSON body. Returns ok=false and responds with 400 if
// the body is invalid or coordinates are out of range.
@(private)
parse_xy_body :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) -> (x, y: f32, ok: bool) {
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return 0, 0, false
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return 0, 0, false
	}
	lua_getfield(L, -1, "x")
	x = f32(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_getfield(L, -1, "y")
	y = f32(lua_tonumber(L, -1))
	lua_pop(L, 1)

	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	if math.is_nan(x) || math.is_nan(y) || math.is_inf(x) || math.is_inf(y) ||
	   x < 0 || y < 0 || x > sw || y > sh {
		respond_json_error(ch, 400, `{"error":"x,y out of range"}`)
		return 0, 0, false
	}
	return x, y, true
}

// --- POST /input/mouse-down ---

handle_post_mouse_down :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	x, y, ok := parse_xy_body(ds, ch, body)
	if !ok do return
	input.fake_mouse_pos = rl.Vector2{x, y}
	input.fake_lmb_down  = true
	append(&ds.event_queue, types.InputEvent(types.MouseEvent{x = x, y = y, button = .LEFT}))
	respond_json_ok(ch)
}

// --- POST /input/mouse-move ---

handle_post_mouse_move :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	x, y, ok := parse_xy_body(ds, ch, body)
	if !ok do return
	input.fake_mouse_pos = rl.Vector2{x, y}
	// fake_lmb_down is unchanged — move-while-held is detected via threshold
	respond_json_ok(ch)
}

// --- POST /input/mouse-up ---

handle_post_mouse_up :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	// x,y are optional. Parse them only if present and non-empty.
	if len(strings.trim_space(body)) > 2 {
		// Body is non-trivial; try to parse x,y. We use the same Lua decoder
		// but only update fake_mouse_pos when x,y are valid numbers.
		L := ds.bridge.L
		pos := 0
		if !json_decode_value(L, body, &pos) {
			respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
			return
		}
		defer lua_pop(L, 1)
		if lua_istable(L, -1) {
			lua_getfield(L, -1, "x")
			xv := f32(lua_tonumber(L, -1))
			lua_pop(L, 1)
			lua_getfield(L, -1, "y")
			yv := f32(lua_tonumber(L, -1))
			lua_pop(L, 1)
			sw := f32(rl.GetScreenWidth())
			sh := f32(rl.GetScreenHeight())
			if !math.is_nan(xv) && !math.is_nan(yv) &&
			   !math.is_inf(xv) && !math.is_inf(yv) &&
			   xv >= 0 && yv >= 0 && xv <= sw && yv <= sh {
				input.fake_mouse_pos = rl.Vector2{xv, yv}
			}
		}
	}
	input.fake_lmb_down = false
	respond_json_ok(ch)
}

// --- POST /input/key ---

handle_post_key :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return
	}

	// Read key name
	lua_getfield(L, -1, "key")
	key_cstr := lua_tostring_raw(L, -1)
	key_str := string(key_cstr)
	lua_pop(L, 1)

	// Use the shared string_to_key from bridge.odin (returns .KEY_NULL for unknowns).
	rl_key := string_to_key(strings.to_lower(key_str, context.temp_allocator))
	if rl_key == .KEY_NULL {
		respond_json_error(ch, 400, `{"error":"unknown key name"}`)
		return
	}

	// Optional mods object
	mods: types.KeyMods
	lua_getfield(L, -1, "mods")
	if lua_istable(L, -1) {
		lua_getfield(L, -1, "shift")
		mods.shift = lua_toboolean(L, -1) != 0
		lua_pop(L, 1)
		lua_getfield(L, -1, "ctrl")
		mods.ctrl = lua_toboolean(L, -1) != 0
		lua_pop(L, 1)
		lua_getfield(L, -1, "alt")
		mods.alt = lua_toboolean(L, -1) != 0
		lua_pop(L, 1)
		lua_getfield(L, -1, "super")
		mods.super = lua_toboolean(L, -1) != 0
		lua_pop(L, 1)
	}
	lua_pop(L, 1)

	// Use fake mouse pos if set, else 0,0
	mx: f32 = 0
	my: f32 = 0
	if pos_v, pos_ok := input.fake_mouse_pos.?; pos_ok {
		mx = pos_v.x
		my = pos_v.y
	}

	append(&ds.event_queue, types.InputEvent(types.KeyEvent{
		x   = mx,
		y   = my,
		key = rl_key,
		mods = mods,
	}))
	respond_json_ok(ch)
}

// --- Screenshot ---

handle_screenshot :: proc(ch: ^Response_Channel) {
	// Encode PNG in-memory (no temp file). Avoids the fixed-path
	// TOCTOU where a local attacker could symlink-swap a predictable
	// /tmp path between export and readback. Raylib returns a buffer
	// we own via MemFree. respond_binary blocks until the response
	// has been sent, so the buffer stays valid across the send and
	// we free exactly once on return.
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)

	size: i32 = 0
	ptr := rl.ExportImageToMemory(image, ".png", &size)
	if ptr == nil || size <= 0 {
		respond_text(ch, 500, "Failed to capture screenshot")
		return
	}
	defer rl.MemFree(ptr)

	data := ([^]u8)(ptr)[:int(size)]
	respond_binary(ch, "image/png", data)
}
