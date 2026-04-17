package bridge

import "core:container/queue"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
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
	server_thread:      ^thread.Thread,
	incoming:           Sync_Queue,
	event_queue:        [dynamic]types.InputEvent,
	running:            bool,
	shutdown_requested: bool,
}

PORT_FILE :: ".redin-port"
PORT_BASE :: 8800
PORT_RANGE :: 100

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

	port_str := fmt.tprintf("%d", bound_port)
	if err := os.write_entire_file(PORT_FILE, port_str); err != nil {
		fmt.eprintfln("Warning: could not write %s: %v", PORT_FILE, err)
	}

	ds.server_thread = thread.create_and_start_with_poly_data(ds, server_thread_proc, context)
	fmt.printfln("Dev server listening on http://localhost:%d", bound_port)
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
	}
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

server_thread_proc :: proc(ds: ^Dev_Server) {
	stack_buf: [8192]u8
	MAX_BODY :: 1024 * 1024

	for ds.running {
		client, _, accept_err := net.accept_tcp(ds.tcp_sock)
		if accept_err != nil || !ds.running {
			break
		}

		buf: []u8 = stack_buf[:]
		heap_buf: []u8
		defer if heap_buf != nil do delete(heap_buf)

		// Read full request into buffer
		total := 0
		too_large := false
		for {
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

		if too_large {
			resp := "HTTP/1.1 413 Payload Too Large\r\n" + CORS_HEADERS + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
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

		// Extract body (after double CRLF)
		body := ""
		if header_end := strings.index(req_str, "\r\n\r\n"); header_end >= 0 {
			body_start := header_end + 4
			if body_start < total {
				body = req_str[body_start:]
			}
		}

		// Handle OPTIONS directly
		if method == "OPTIONS" {
			options_resp := "HTTP/1.1 204 No Content\r\n" + CORS_HEADERS + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			net.send_tcp(client, transmute([]u8)options_resp)
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
		send_str(client, "\r\n")
		send_str(client, CORS_HEADERS)
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

CORS_HEADERS :: "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type"

find_content_length :: proc(headers: string) -> int {
	lower := strings.to_lower(headers, context.temp_allocator)
	idx := strings.index(lower, "content-length:")
	if idx < 0 do return 0
	rest := strings.trim_left_space(headers[idx + len("content-length:"):])
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
	case 403: return "403 Forbidden"
	case 404: return "404 Not Found"
	case 405: return "405 Method Not Allowed"
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
		} else if req.path == "/screenshot" {
			handle_screenshot(ch)
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
			handle_post_resize(ch, req.body)
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
	segments := strings.split(dot_path, ".")
	defer delete(segments)
	for seg in segments {
		if lua_istable(L, -1) {
			s := strings.clone_to_cstring(seg)
			defer delete(s)
			lua_getfield(L, -1, s)
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
	L := ds.bridge.L
	pos := 0
	if json_decode_value(L, body, &pos) && lua_istable(L, -1) {
		lua_getfield(L, -1, "x")
		x := f32(lua_tonumber(L, -1))
		lua_pop(L, 1)
		lua_getfield(L, -1, "y")
		y := f32(lua_tonumber(L, -1))
		lua_pop(L, 1)
		lua_pop(L, 1)
		append(&ds.event_queue, types.InputEvent(types.MouseEvent{x = x, y = y, button = .LEFT}))
	}
	respond_json_ok(ch)
}

handle_post_resize :: proc(ch: ^Response_Channel, body: string) {
	// Parse body without leaving a value on the Lua stack — we only need width/height.
	width, height := 0, 0
	{
		// Minimal hand-parse: { "width": N, "height": M }
		b := body
		find_int :: proc(b: string, key: string) -> int {
			i := strings.index(b, key)
			if i < 0 do return 0
			rest := b[i + len(key):]
			colon := strings.index_byte(rest, ':')
			if colon < 0 do return 0
			rest = strings.trim_left_space(rest[colon + 1:])
			n := 0
			for j := 0; j < len(rest); j += 1 {
				c := rest[j]
				if c >= '0' && c <= '9' {
					n = n * 10 + int(c - '0')
				} else if n > 0 {
					break
				} else if c != ' ' && c != '\t' {
					break
				}
			}
			return n
		}
		width = find_int(b, "\"width\"")
		height = find_int(b, "\"height\"")
	}
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

// --- Screenshot ---

handle_screenshot :: proc(ch: ^Response_Channel) {
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	tmp_path: cstring = "/tmp/redin_screenshot.png"
	rl.ExportImage(image, tmp_path)
	data, read_err := os.read_entire_file_from_path("/tmp/redin_screenshot.png", context.allocator)
	if read_err != nil {
		respond_text(ch, 500, "Failed to capture screenshot")
		return
	}
	defer delete(data)
	respond_binary(ch, "image/png", data)
	os.remove("/tmp/redin_screenshot.png")
}
