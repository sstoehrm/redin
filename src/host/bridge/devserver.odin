package bridge

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "../types"
import rl "vendor:raylib"

Dev_Server :: struct {
	bridge:             ^Bridge,
	listener:           net.TCP_Socket,
	event_queue:        [dynamic]types.InputEvent,
	running:            bool,
	shutdown_requested: bool,
}

devserver_init :: proc(ds: ^Dev_Server, b: ^Bridge) {
	ds.bridge = b
	ds.running = true

	endpoint := net.Endpoint {
		address = net.IP4_Loopback,
		port    = 8800,
	}
	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintfln("Dev server failed to listen: %v", err)
		ds.running = false
		return
	}
	ds.listener = sock
	net.set_blocking(ds.listener, false)
	fmt.println("Dev server listening on http://localhost:8800")
}

devserver_destroy :: proc(ds: ^Dev_Server) {
	if ds.running {
		ds.running = false
		net.close(ds.listener)
	}
	delete(ds.event_queue)
}

devserver_poll :: proc(ds: ^Dev_Server) {
	if !ds.running do return

	client, _, err := net.accept_tcp(ds.listener)
	if err != nil do return

	buf: [4096]u8
	bytes_read, read_err := net.recv_tcp(client, buf[:])
	if read_err != nil || bytes_read <= 0 {
		net.close(client)
		return
	}

	request := string(buf[:bytes_read])
	devserver_handle_request(ds, client, request)
	net.close(client)
}

devserver_drain_events :: proc(ds: ^Dev_Server, events: ^[dynamic]types.InputEvent) {
	for &event in ds.event_queue {
		append(events, event)
	}
	clear(&ds.event_queue)
}

// ---------------------------------------------------------------------------
// Request routing
// ---------------------------------------------------------------------------

devserver_handle_request :: proc(ds: ^Dev_Server, client: net.TCP_Socket, request: string) {
	first_line_end := strings.index(request, "\r\n")
	if first_line_end < 0 do first_line_end = strings.index(request, "\n")
	if first_line_end < 0 {
		send_response(client, 400, "text/plain", "Bad request")
		return
	}
	parts := strings.split(request[:first_line_end], " ")
	defer delete(parts)
	if len(parts) < 2 {
		send_response(client, 400, "text/plain", "Bad request")
		return
	}
	method := parts[0]
	path := parts[1]

	body := ""
	body_start := strings.index(request, "\r\n\r\n")
	if body_start >= 0 do body = request[body_start + 4:]

	if method == "OPTIONS" {
		send_cors(client)
		return
	}

	switch method {
	case "GET":
		handle_get(ds, client, path)
	case "POST":
		handle_post(ds, client, path, body)
	case "PUT":
		handle_put(ds, client, path, body)
	case:
		send_response(client, 405, "text/plain", "Method not allowed")
	}
}

// ---------------------------------------------------------------------------
// GET
// ---------------------------------------------------------------------------

handle_get :: proc(ds: ^Dev_Server, client: net.TCP_Socket, path: string) {
	if path == "/frames" {
		handle_get_frames(ds, client)
	} else if path == "/state" {
		handle_get_state(ds, client)
	} else if strings.has_prefix(path, "/state/") {
		handle_get_state_path(ds, client, path[len("/state/"):])
	} else if path == "/aspects" {
		handle_get_aspects(ds, client)
	} else if path == "/screenshot" {
		handle_screenshot(client)
	} else {
		send_response(client, 404, "text/plain", "Not found")
	}
}

handle_get_frames :: proc(ds: ^Dev_Server, client: net.TCP_Socket) {
	L := ds.bridge.L
	lua_getglobal(L, "require")
	lua_pushstring(L, "view")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		send_response(client, 500, "application/json", `{"error":"lua error"}`)
		return
	}
	lua_getfield(L, -1, "get-last-push")
	lua_remove(L, -2)
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		send_response(client, 500, "application/json", `{"error":"lua error"}`)
		return
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	lua_value_to_json(&b, L, -1)
	lua_pop(L, 1)
	send_response(client, 200, "application/json", strings.to_string(b))
}

handle_get_state :: proc(ds: ^Dev_Server, client: net.TCP_Socket) {
	L := ds.bridge.L
	lua_getglobal(L, "redin_get_state")
	if !lua_isnil(L, -1) {
		if lua_pcall(L, 0, 1, 0) == 0 {
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			lua_value_to_json(&b, L, -1)
			lua_pop(L, 1)
			send_response(client, 200, "application/json", strings.to_string(b))
		} else {
			lua_pop(L, 1)
			send_response(client, 500, "application/json", `{"error":"lua error"}`)
		}
	} else {
		lua_pop(L, 1)
		send_response(client, 200, "application/json", "{}")
	}
}

handle_get_state_path :: proc(ds: ^Dev_Server, client: net.TCP_Socket, dot_path: string) {
	L := ds.bridge.L
	lua_getglobal(L, "redin_get_state")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		send_response(client, 200, "application/json", "null")
		return
	}
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		send_response(client, 500, "application/json", `{"error":"lua error"}`)
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
	send_response(client, 200, "application/json", strings.to_string(b))
}

handle_get_aspects :: proc(ds: ^Dev_Server, client: net.TCP_Socket) {
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
	send_response(client, 200, "application/json", strings.to_string(b))
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

// ---------------------------------------------------------------------------
// POST
// ---------------------------------------------------------------------------

handle_post :: proc(ds: ^Dev_Server, client: net.TCP_Socket, path: string, body: string) {
	if path == "/events" {
		L := ds.bridge.L
		lua_getglobal(L, "redin_events")
		if lua_isnil(L, -1) {
			lua_pop(L, 1)
			send_response(client, 500, "application/json", `{"error":"no event handler"}`)
			return
		}
		pos := 0
		if !json_decode_value(L, body, &pos) {
			lua_pop(L, 1)
			send_response(client, 400, "application/json", `{"error":"invalid JSON"}`)
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
		send_response(client, 200, "application/json", `{"ok":true}`)
	} else if path == "/click" {
		x := extract_number(body, `"x"`)
		y := extract_number(body, `"y"`)
		append(
			&ds.event_queue,
			types.InputEvent(types.MouseEvent{x = x, y = y, button = .LEFT}),
		)
		send_response(client, 200, "application/json", `{"ok":true}`)
	} else if path == "/shutdown" {
		ds.shutdown_requested = true
		send_response(client, 200, "application/json", `{"ok":true}`)
	} else {
		send_response(client, 404, "text/plain", "Not found")
	}
}

// ---------------------------------------------------------------------------
// PUT
// ---------------------------------------------------------------------------

handle_put :: proc(ds: ^Dev_Server, client: net.TCP_Socket, path: string, body: string) {
	if path == "/aspects" {
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
		send_response(client, 200, "application/json", `{"ok":true}`)
	} else {
		send_response(client, 404, "text/plain", "Not found")
	}
}

// ---------------------------------------------------------------------------
// Screenshot
// ---------------------------------------------------------------------------

handle_screenshot :: proc(client: net.TCP_Socket) {
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)

	tmp_path: cstring = "/tmp/redin_screenshot.png"
	rl.ExportImage(image, tmp_path)

	data, read_err := os.read_entire_file_from_path("/tmp/redin_screenshot.png", context.allocator)
	if read_err != nil {
		send_response(client, 500, "text/plain", "Failed to capture screenshot")
		return
	}
	defer delete(data)

	send_binary(client, 200, "image/png", data)
	os.remove("/tmp/redin_screenshot.png")
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

send_response :: proc(client: net.TCP_Socket, status: int, content_type: string, body: string) {
	status_text: string
	switch status {
	case 200:
		status_text = "OK"
	case 400:
		status_text = "Bad Request"
	case 403:
		status_text = "Forbidden"
	case 404:
		status_text = "Not Found"
	case 405:
		status_text = "Method Not Allowed"
	case 500:
		status_text = "Internal Server Error"
	case:
		status_text = "OK"
	}
	response := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n%s",
		status, status_text, content_type, len(body), body,
	)
	net.send_tcp(client, transmute([]u8)response)
}

send_cors :: proc(client: net.TCP_Socket) {
	response := fmt.tprintf(
		"HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Max-Age: 86400\r\nConnection: close\r\n\r\n",
	)
	net.send_tcp(client, transmute([]u8)response)
}

send_binary :: proc(client: net.TCP_Socket, status: int, content_type: string, body: []u8) {
	header := fmt.tprintf(
		"HTTP/1.1 %d OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
		status, content_type, len(body),
	)
	net.send_tcp(client, transmute([]u8)header)
	net.send_tcp(client, body)
}

extract_number :: proc(body: string, key: string) -> f32 {
	ki := strings.index(body, key)
	if ki < 0 do return 0
	rest := body[ki + len(key):]
	for i in 0 ..< len(rest) {
		if rest[i] == ':' || rest[i] == ' ' do continue
		num_start := i
		num_end := i
		for j in i ..< len(rest) {
			c := rest[j]
			if (c >= '0' && c <= '9') || c == '.' || c == '-' {
				num_end = j + 1
			} else {
				break
			}
		}
		if num_end > num_start {
			val: f32 = 0
			frac: f32 = 0
			frac_div: f32 = 1
			neg: f32 = 1
			in_frac := false
			for c in rest[num_start:num_end] {
				if c == '-' {
					neg = -1
				} else if c == '.' {
					in_frac = true
				} else if c >= '0' && c <= '9' {
					if in_frac {
						frac_div *= 10
						frac += f32(c - '0') / frac_div
					} else {
						val = val * 10 + f32(c - '0')
					}
				}
			}
			return (val + frac) * neg
		}
		break
	}
	return 0
}
