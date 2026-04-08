package bridge

import "core:container/queue"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import http "../../../lib/odin-http"
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
	status:       http.Status,
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
	server:             http.Server,
	server_thread:      ^thread.Thread,
	incoming:           Sync_Queue,
	event_queue:        [dynamic]types.InputEvent,
	running:            bool,
	shutdown_requested: bool,
}

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
	ds.server_thread = thread.create_and_start_with_poly_data(ds, server_thread_proc, context)
	fmt.println("Dev server listening on http://localhost:8800")
}

devserver_destroy :: proc(ds: ^Dev_Server) {
	if ds.running {
		ds.running = false
		http.server_shutdown(&ds.server)
		if ds.server_thread != nil {
			thread.join(ds.server_thread)
			thread.destroy(ds.server_thread)
		}
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

// --- Server thread ---

server_thread_proc :: proc(ds: ^Dev_Server) {
	h := http.Handler{
		user_data = ds,
		handle = server_request_handler,
	}
	endpoint := net.Endpoint{
		address = net.IP4_Loopback,
		port = 8800,
	}
	opts := http.Default_Server_Opts
	opts.thread_count = 1
	err := http.listen_and_serve(&ds.server, h, endpoint, opts)
	if err != nil {
		fmt.eprintfln("Dev server error: %v", err)
		ds.running = false
	}
}

// --- odin-http handler ---

server_request_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	ds := (^Dev_Server)(h.user_data)

	// Loopback check
	switch a in req.client.address {
	case net.IP4_Address:
		if a != net.IP4_Loopback {
			res.status = .Forbidden
			http.body_set(res, "Forbidden")
			http.respond(res)
			return
		}
	case net.IP6_Address:
		if a != net.IP6_Loopback {
			res.status = .Forbidden
			http.body_set(res, "Forbidden")
			http.respond(res)
			return
		}
	}

	rline, rline_ok := req.line.(http.Requestline)
	if !rline_ok {
		res.status = .Bad_Request
		http.body_set(res, "Bad request")
		http.respond(res)
		return
	}

	if rline.method == .Options {
		res.status = .No_Content
		set_cors_headers(res)
		http.headers_set(&res.headers, "access-control-max-age", "86400")
		http.respond(res)
		return
	}

	ctx := new(Body_Handler_Context)
	ctx.ds = ds
	ctx.path = strings.clone(req.url.path)
	ctx.method = rline.method
	ctx.res = res
	http.body(req, -1, ctx, body_handler_callback)
}

Body_Handler_Context :: struct {
	ds:     ^Dev_Server,
	path:   string,
	method: http.Method,
	res:    ^http.Response,
}

body_handler_callback :: proc(user_data: rawptr, body_str: http.Body, err: http.Body_Error) {
	ctx := (^Body_Handler_Context)(user_data)
	defer {
		delete(ctx.path)
		free(ctx)
	}

	if err != nil {
		ctx.res.status = .Bad_Request
		http.body_set(ctx.res, "Bad request body")
		set_cors_headers(ctx.res)
		http.respond(ctx.res)
		return
	}

	dispatch_to_main(ctx.ds, http.method_string(ctx.method), ctx.path, string(body_str), ctx.res)
}

dispatch_to_main :: proc(ds: ^Dev_Server, method: string, path: string, body: string, res: ^http.Response) {
	channel: Response_Channel
	pending := new(Pending_Request)
	pending.method = method
	pending.path = path
	pending.body = body
	pending.response = &channel

	sync_queue_push(&ds.incoming, pending)
	sync.sema_wait(&channel.done)

	res.status = channel.status
	set_cors_headers(res)
	if len(channel.content_type) > 0 {
		http.headers_set_content_type(&res.headers, channel.content_type)
	}
	if len(channel.binary) > 0 {
		http.body_set(res, channel.binary)
	} else if len(channel.body) > 0 {
		http.body_set(res, channel.body)
	}
	http.respond(res)

	sync.sema_post(&channel.ack)
	free(pending)
}

set_cors_headers :: proc(res: ^http.Response) {
	http.headers_set(&res.headers, "access-control-allow-origin", "http://localhost:8800")
	http.headers_set(&res.headers, "access-control-allow-methods", "GET, POST, PUT, OPTIONS")
	http.headers_set(&res.headers, "access-control-allow-headers", "Content-Type")
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
			respond_text(ch, .Not_Found, "Not found")
		}
	case "POST":
		if req.path == "/events" {
			handle_post_events(ds, ch, req.body)
		} else if req.path == "/click" {
			handle_post_click(ds, ch, req.body)
		} else if req.path == "/shutdown" {
			ds.shutdown_requested = true
			respond_json_ok(ch)
		} else {
			respond_text(ch, .Not_Found, "Not found")
		}
	case "PUT":
		if req.path == "/aspects" {
			handle_put_aspects(ds, ch, req.body)
		} else {
			respond_text(ch, .Not_Found, "Not found")
		}
	case:
		respond_text(ch, .Method_Not_Allowed, "Method not allowed")
	}
}

// --- Response helpers ---

respond_json :: proc(ch: ^Response_Channel, body: string) {
	ch.status = .OK
	ch.content_type = "application/json"
	ch.body = body
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_json_ok :: proc(ch: ^Response_Channel) {
	ch.status = .OK
	ch.content_type = "application/json"
	ch.body = `{"ok":true}`
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_json_error :: proc(ch: ^Response_Channel, status: http.Status, msg: string) {
	ch.status = status
	ch.content_type = "application/json"
	ch.body = msg
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_text :: proc(ch: ^Response_Channel, status: http.Status, body: string) {
	ch.status = status
	ch.content_type = "text/plain"
	ch.body = body
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

respond_binary :: proc(ch: ^Response_Channel, content_type: string, data: []u8) {
	ch.status = .OK
	ch.content_type = content_type
	ch.binary = data
	sync.sema_post(&ch.done)
	sync.sema_wait(&ch.ack)
}

// --- GET handlers ---
// (same Lua logic as before, writing to Response_Channel instead of socket)

handle_get_frames :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	L := ds.bridge.L
	lua_getglobal(L, "require")
	lua_pushstring(L, "view")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, .Internal_Server_Error, `{"error":"lua error"}`)
		return
	}
	lua_getfield(L, -1, "get-last-push")
	lua_remove(L, -2)
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, .Internal_Server_Error, `{"error":"lua error"}`)
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
			respond_json_error(ch, .Internal_Server_Error, `{"error":"lua error"}`)
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
		respond_json_error(ch, .Internal_Server_Error, `{"error":"lua error"}`)
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
		respond_json_error(ch, .Internal_Server_Error, `{"error":"no event handler"}`)
		return
	}
	pos := 0
	if !json_decode_value(L, body, &pos) {
		lua_pop(L, 1)
		respond_json_error(ch, .Bad_Request, `{"error":"invalid JSON"}`)
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
		respond_text(ch, .Internal_Server_Error, "Failed to capture screenshot")
		return
	}
	defer delete(data)
	respond_binary(ch, "image/png", data)
	os.remove("/tmp/redin_screenshot.png")
}
