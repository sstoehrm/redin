package bridge

// Compile-time flag enabling the agent channel feature. Default is false;
// set with `odin build ... -define:REDIN_AGENT=true`. When false, the
// agent endpoints, walker, and listener-gate widening all compile out
// to zero bytes.
REDIN_AGENT :: #config(REDIN_AGENT, false)

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "base:runtime"
import "../font"
import "../input"
import text_pkg "../text"
import "../types"
import rl "vendor:raylib"
import "../canvas"

Bridge :: struct {
	L:               ^Lua_State,
	paths:           [dynamic]types.Path,
	nodes:           [dynamic]types.Node,
	parent_indices:  [dynamic]int,
	children_list:   [dynamic]types.Children,
	node_animations: [dynamic]Maybe(types.Animate_Decoration),
	theme:           map[string]types.Theme,
	http_client:     Http_Client,
	shell_client:    Shell_Client,
	hot_reload:      Hot_Reload,
	dev_server:      Dev_Server,
	frame_changed:   bool,
	dev_mode:        bool,
}

g_bridge: ^Bridge
g_context: runtime.Context

init :: proc(b: ^Bridge, dev_mode: bool) {
	g_bridge = b
	g_context = context
	b.dev_mode = dev_mode
	http_client_init(&b.http_client)
	shell_client_init(&b.shell_client)
	b.L = luaL_newstate()
	luaL_openlibs(b.L)

	exe_dir := filepath.dir(string(os.args[0]))
	lua_pushstring(b.L, strings.clone_to_cstring(exe_dir))
	lua_setglobal(b.L, "_redin_exe_dir")

	setup_lua_paths(b.L)

	// Create redin global table with host functions
	lua_newtable(b.L)
	register_cfunc_init(b.L, "push", redin_push)
	register_cfunc_init(b.L, "set_theme", redin_set_theme)
	register_cfunc_init(b.L, "log", redin_log)
	register_cfunc_init(b.L, "now", redin_now)
	register_cfunc_init(b.L, "measure_text", redin_measure_text)
	register_cfunc_init(b.L, "http", redin_http)
	register_cfunc_init(b.L, "json_encode", redin_json_encode)
	register_cfunc_init(b.L, "json_decode", redin_json_decode)
	register_cfunc_init(b.L, "canvas_register", redin_canvas_register)
	register_cfunc_init(b.L, "canvas_unregister", redin_canvas_unregister)
	register_cfunc_init(b.L, "key_down", redin_key_down)
	register_cfunc_init(b.L, "key_pressed", redin_key_pressed)
	register_cfunc_init(b.L, "shell", redin_shell)
	lua_setglobal(b.L, "redin")

	// Also expose flat globals for the effect system
	lua_pushcfunction(b.L, redin_http)
	lua_setglobal(b.L, "redin_http")
	lua_pushcfunction(b.L, redin_shell)
	lua_setglobal(b.L, "redin_shell")

	// Apply any user cfunc registrations made before bridge.init (the
	// natural pattern: app.odin calls bridge.register_cfunc before
	// redin.run, which is when bridge.init runs).
	flush_pending_cfuncs()

	load_fennel(b.L)
	load_runtime(b.L)

	if dev_mode {
		hotreload_init(&b.hot_reload)
		devserver_init(&b.dev_server, b)
	}
}

destroy :: proc(b: ^Bridge) {
	if b.dev_mode {
		devserver_destroy(&b.dev_server)
		hotreload_destroy(&b.hot_reload)
	}
	http_client_destroy(&b.http_client)
	shell_client_destroy(&b.shell_client)
	clear_frame(b)
	for k in b.theme {
		delete(k)
	}
	delete(b.theme)
	lua_close(b.L)
}

poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent, node_rects: []rl.Rectangle) {
	if !b.dev_mode do return
	b.dev_server.current_rects = node_rects
	devserver_poll(&b.dev_server)
	devserver_drain_events(&b.dev_server, events)
	b.dev_server.current_rects = nil
}

is_shutdown_requested :: proc(b: ^Bridge) -> bool {
	return b.dev_mode && b.dev_server.shutdown_requested
}

check_hotreload :: proc(b: ^Bridge) {
	if !b.dev_mode do return
	if hotreload_check(&b.hot_reload) {
		hotreload_execute(b)
		b.frame_changed = true
	}
}

// Walk the flat tree once: for each draggable with handle_off, ensure at
// least one descendant carries drag_handle. Otherwise the draggable is
// silently ungrabbable. Stops the descendant walk at nested-draggable
// boundaries (handle binds to nearest draggable ancestor).
//
// Logged per-frame in line with the existing parse-warning convention
// (no dedupe).
validate_drag_handles :: proc(
	nodes: []types.Node,
	children_list: []types.Children,
) {
	for node, idx in nodes {
		handle_off := false
		switch n in node {
		case types.NodeVbox:
			if d, ok := n.draggable.?; ok do handle_off = d.handle_off
		case types.NodeHbox:
			if d, ok := n.draggable.?; ok do handle_off = d.handle_off
		case types.NodeStack, types.NodeCanvas, types.NodeInput,
		     types.NodeButton, types.NodeText, types.NodeImage,
		     types.NodePopout, types.NodeModal:
		}
		if !handle_off do continue
		if !subtree_has_drag_handle(idx, nodes, children_list) {
			fmt.eprintfln(
				":draggable at idx %d has :handle false but no descendant :drag-handle true — ungrabbable",
				idx,
			)
		}
	}
}

// True iff any descendant of `root` carries drag_handle == true.
// Stops descent at nested-draggable boundaries.
subtree_has_drag_handle :: proc(
	root: int,
	nodes: []types.Node,
	children_list: []types.Children,
) -> bool {
	if root < 0 || root >= len(children_list) do return false
	kids := children_list[root]
	for i in 0 ..< int(kids.length) {
		ci := int(kids.value[i])
		if ci < 0 || ci >= len(nodes) do continue
		nested := false
		// Edge case: a node that is BOTH a draggable container and carries
		// drag_handle = true counts as a handle for *this* outer draggable
		// (we report `return true` before checking `nested`). This is exotic;
		// idiomatic apps don't combine the two on one node.
		switch n in nodes[ci] {
		case types.NodeVbox:
			if _, ok := n.draggable.?; ok do nested = true
			if n.drag_handle do return true
		case types.NodeHbox:
			if _, ok := n.draggable.?; ok do nested = true
			if n.drag_handle do return true
		case types.NodeButton:
			if n.drag_handle do return true
		case types.NodeStack, types.NodeCanvas, types.NodeInput,
		     types.NodeText, types.NodeImage, types.NodePopout,
		     types.NodeModal:
		}
		if !nested && subtree_has_drag_handle(ci, nodes, children_list) do return true
	}
	return false
}

clear_draggable_attrs :: proc(m: Maybe(types.Draggable_Attrs)) {
	d, ok := m.?
	if !ok do return
	for s in d.tags do delete(s)
	if d.tags != nil do delete(d.tags)
	if len(d.event) > 0 do delete(d.event)
	if len(d.aspect) > 0 do delete(d.aspect)
	if dec, ok2 := d.animate.?; ok2 && len(dec.provider) > 0 do delete(dec.provider)
	if d.ctx != 0 {
		// Don't unref the Lua registry slot while a drag is in flight and
		// the captured ctx_ref refers to this very slot. The node may be
		// re-rendered (and its ctx unreffed) before the drop fires, which
		// would free the slot prematurely and deliver nil to the drop handler.
		active_ref: i32 = 0
		switch s in input.drag {
		case input.Drag_Pending: active_ref = s.src_ctx_ref
		case input.Drag_Active:  active_ref = s.src_ctx_ref
		case nil, input.Drag_Idle:
		}
		if d.ctx != active_ref {
			luaL_unref(g_bridge.L, LUA_REGISTRYINDEX, d.ctx)
		}
	}
}

clear_dropable_attrs :: proc(m: Maybe(types.Dropable_Attrs)) {
	d, ok := m.?
	if !ok do return
	for s in d.tags do delete(s)
	if d.tags != nil do delete(d.tags)
	if len(d.event) > 0 do delete(d.event)
	if len(d.aspect) > 0 do delete(d.aspect)
	if dec, ok2 := d.animate.?; ok2 && len(dec.provider) > 0 do delete(dec.provider)
	if d.ctx != 0 do luaL_unref(g_bridge.L, LUA_REGISTRYINDEX, d.ctx)
}

clear_drag_over_attrs :: proc(m: Maybe(types.Drag_Over_Attrs)) {
	d, ok := m.?
	if !ok do return
	for s in d.tags do delete(s)
	if d.tags != nil do delete(d.tags)
	if len(d.event) > 0 do delete(d.event)
	if len(d.aspect) > 0 do delete(d.aspect)
	if dec, ok2 := d.animate.?; ok2 && len(dec.provider) > 0 do delete(dec.provider)
}

clear_node_strings :: proc(n: types.Node) {
	switch v in n {
	case types.NodeStack:
		if v.viewport != nil do delete(v.viewport)
	case types.NodeCanvas:
		if len(v.provider) > 0 do delete(v.provider)
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeVbox:
		if len(v.overflow) > 0 do delete(v.overflow)
		if len(v.aspect) > 0 do delete(v.aspect)
		clear_draggable_attrs(v.draggable)
		clear_dropable_attrs(v.dropable)
		clear_drag_over_attrs(v.drag_over)
	case types.NodeHbox:
		if len(v.overflow) > 0 do delete(v.overflow)
		if len(v.aspect) > 0 do delete(v.aspect)
		clear_draggable_attrs(v.draggable)
		clear_dropable_attrs(v.dropable)
		clear_drag_over_attrs(v.drag_over)
	case types.NodeInput:
		if len(v.change) > 0 do delete(v.change)
		if len(v.key) > 0 do delete(v.key)
		if len(v.aspect) > 0 do delete(v.aspect)
		if len(v.value) > 0 do delete(v.value)
		if len(v.placeholder) > 0 do delete(v.placeholder)
		if len(v.overflow) > 0 do delete(v.overflow)
	case types.NodeButton:
		if len(v.click) > 0 do delete(v.click)
		if len(v.label) > 0 do delete(v.label)
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeText:
		if len(v.content) > 0 do delete(v.content)
		if len(v.aspect) > 0 do delete(v.aspect)
		if len(v.overflow) > 0 do delete(v.overflow)
	case types.NodeImage:
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodePopout:
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeModal:
		if len(v.aspect) > 0 do delete(v.aspect)
	}
}

clear_frame :: proc(b: ^Bridge) {
	// Any cross-frame caches keyed by node string pointers become stale
	// the moment strings are freed. Invalidate before any delete calls.
	text_pkg.invalidate_height_cache()

	for &p in b.paths {
		delete(p.value)
	}
	delete(b.paths)
	b.paths = {}
	for &n in b.nodes {
		clear_node_strings(n)
	}
	delete(b.nodes)
	b.nodes = {}
	delete(b.parent_indices)
	b.parent_indices = {}
	for &c in b.children_list {
		delete(c.value)
	}
	delete(b.children_list)
	b.children_list = {}
	for entry in b.node_animations {
		if d, has := entry.?; has && len(d.provider) > 0 {
			delete(d.provider)
		}
	}
	delete(b.node_animations)
	b.node_animations = {}
}

// ---------------------------------------------------------------------------
// Host functions (Lua C callbacks)
// ---------------------------------------------------------------------------

redin_log :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	n := lua_gettop(L)
	for i: i32 = 1; i <= n; i += 1 {
		if i > 1 do fmt.print("\t")
		t := lua_type(L, i)
		switch t {
		case LUA_TSTRING:
			fmt.print(string(lua_tostring_raw(L, i)))
		case LUA_TNUMBER:
			fmt.print(lua_tonumber(L, i))
		case LUA_TBOOLEAN:
			fmt.print(lua_toboolean(L, i) != 0 ? "true" : "false")
		case LUA_TNIL:
			fmt.print("nil")
		case:
			fmt.print(lua_typename(L, t))
		}
	}
	fmt.println()
	return 0
}

redin_now :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	t := time.now()
	secs := f64(time.to_unix_nanoseconds(t)) / 1e9
	lua_pushnumber(L, secs)
	return 1
}

redin_measure_text :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	text := lua_tostring_raw(L, 1)
	font_size := f32(lua_tonumber(L, 2))
	font_name := "sans"
	if lua_isstring(L, 3) {
		font_name = string(lua_tostring_raw(L, 3))
	}
	f := font.get(font_name, .Regular)
	spacing := max(font_size / 10, 1)
	size := rl.MeasureTextEx(f, text, font_size, spacing)
	lua_pushnumber(L, f64(size.x))
	lua_pushnumber(L, f64(size.y))
	return 2
}

// redin.push(frame) — convert Lua frame table to flat parallel arrays
redin_push :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if g_bridge == nil do return 0

	clear_frame(g_bridge)

	if lua_istable(L, 1) {
		cur: [dynamic]u8
		defer delete(cur)
		lua_flatten_node(L, 1, &cur, g_bridge, -1)
	}

	g_bridge.frame_changed = true
	return 0
}

// redin.set_theme(theme) — convert Lua theme table to map[string]Theme
redin_set_theme :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if g_bridge == nil do return 0
	if lua_istable(L, 1) {
		// Load font-face declarations before processing theme
		lua_getfield(L, 1, "font-face")
		if lua_istable(L, -1) {
			load_font_faces(L, lua_gettop(L))
		}
		lua_pop(L, 1)

		// Clear old theme
		for k in g_bridge.theme {
			delete(k)
		}
		delete(g_bridge.theme)
		g_bridge.theme = lua_to_theme(L, 1)

		// Theme params (font_size, lh_ratio, font atlas) feed cached
		// intrinsic heights; invalidate since the cache is idx-keyed
		// and doesn't detect indirect param changes on its own.
		text_pkg.invalidate_height_cache()
	}
	return 0
}

// redin.http(id, url, method, headers, body, timeout) — queue async HTTP request
redin_http :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if g_bridge == nil do return 0

	req: Http_Request
	req.headers = make(map[string]string)

	if lua_isstring(L, 1) do req.id = strings.clone_from_cstring(lua_tostring_raw(L, 1))
	if lua_isstring(L, 2) do req.url = strings.clone_from_cstring(lua_tostring_raw(L, 2))
	if lua_isstring(L, 3) {
		req.method = strings.clone_from_cstring(lua_tostring_raw(L, 3))
	} else {
		req.method = strings.clone("GET")
	}
	if lua_istable(L, 4) {
		headers_idx := i32(4)
		lua_pushnil(L)
		for lua_next(L, headers_idx) != 0 {
			if lua_isstring(L, -2) && lua_isstring(L, -1) {
				k := strings.clone_from_cstring(lua_tostring_raw(L, -2))
				v := strings.clone_from_cstring(lua_tostring_raw(L, -1))
				req.headers[k] = v
			}
			lua_pop(L, 1)
		}
	}
	if lua_isstring(L, 5) {
		req.body = strings.clone_from_cstring(lua_tostring_raw(L, 5))
	} else {
		req.body = strings.clone("")
	}

	http_client_request(&g_bridge.http_client, req)
	return 0
}

// ---------------------------------------------------------------------------
// Fennel canvas provider
// ---------------------------------------------------------------------------

fennel_canvas_update :: proc(rect: rl.Rectangle) {
	if g_bridge == nil do return
	lua_canvas_draw(g_bridge, canvas.current_name, rect)
}

fennel_canvas_provider := canvas.Canvas_Provider {
	start   = nil,
	update  = fennel_canvas_update,
	suspend = nil,
	stop    = nil,
}

redin_canvas_register :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if lua_isstring(L, 1) {
		name := strings.clone_from_cstring(lua_tostring_raw(L, 1))
		canvas.register(name, fennel_canvas_provider)
	}
	return 0
}

redin_canvas_unregister :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if lua_isstring(L, 1) {
		name := string(lua_tostring_raw(L, 1))
		canvas.unregister(name)
	}
	return 0
}

// ---------------------------------------------------------------------------
// Canvas draw helpers
// ---------------------------------------------------------------------------

// Read a number from a Lua table at integer index
lua_rawgeti_number :: proc(L: ^Lua_State, idx: i32, i: i32) -> f64 {
	lua_rawgeti(L, idx, i)
	defer lua_pop(L, 1)
	return lua_tonumber(L, -1)
}

// Clamp an arbitrary numeric value to a u8. Used for canvas colour
// components — pre-fix they were truncated via `u8(...)`, so a buggy
// Fennel provider returning {255, 256, -1} silently rendered the wrong
// colour. Issue #78 finding L3.
clamp_byte :: proc(n: f64) -> u8 {
	if math.is_nan(n) do return 0
	if n <= 0 do return 0
	if n >= 255 do return 255
	return u8(n)
}

// Sanitize a canvas dimension (width / height / radius / coordinate
// magnitude). Bails on NaN, Inf, negative, or above the texture-side
// ceiling, so a malformed canvas command can be skipped instead of
// flowing junk into Raylib's draw calls. Issue #78 finding L3.
@(private = "file")
DIM_MAX :: 16384

sanitize_dim :: proc(v: f32) -> (f32, bool) {
	if math.is_nan(v) || math.is_inf(v) do return 0, false
	if v < 0 || v > DIM_MAX do return 0, false
	return v, true
}

// Read a color [r,g,b] or [r,g,b,a] from a table field. Returns ok=false if field missing.
read_color_field :: proc(L: ^Lua_State, idx: i32, field: cstring) -> (rl.Color, bool) {
	lua_getfield(L, idx, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}, false

	color_idx := lua_gettop(L)
	r := clamp_byte(lua_rawgeti_number(L, color_idx, 1))
	g := clamp_byte(lua_rawgeti_number(L, color_idx, 2))
	b := clamp_byte(lua_rawgeti_number(L, color_idx, 3))

	lua_rawgeti(L, color_idx, 4)
	a := u8(255)
	if lua_isnumber(L, -1) {
		a = clamp_byte(lua_tonumber(L, -1))
	}
	lua_pop(L, 1)

	return rl.Color{r, g, b, a}, true
}

// Read a number field from a Lua table, default 0
read_number_field :: proc(L: ^Lua_State, idx: i32, field: cstring) -> f32 {
	lua_getfield(L, idx, field)
	defer lua_pop(L, 1)
	if lua_isnumber(L, -1) {
		return f32(lua_tonumber(L, -1))
	}
	return 0
}

// ---------------------------------------------------------------------------
// Mouse input state builder
// ---------------------------------------------------------------------------

// Push a {left=bool, right=bool, middle=bool} table for a mouse button query
push_mouse_buttons :: proc(L: ^Lua_State, parent_idx: i32, field: cstring, query: proc(button: rl.MouseButton) -> bool) {
	lua_createtable(L, 0, 3)
	btn_idx := lua_gettop(L)
	lua_pushboolean(L, query(.LEFT) ? 1 : 0)
	lua_setfield(L, btn_idx, "left")
	lua_pushboolean(L, query(.RIGHT) ? 1 : 0)
	lua_setfield(L, btn_idx, "right")
	lua_pushboolean(L, query(.MIDDLE) ? 1 : 0)
	lua_setfield(L, btn_idx, "middle")
	lua_setfield(L, parent_idx, field)
}

// Build a Lua table with mouse state for canvas draw functions
push_canvas_input_state :: proc(L: ^Lua_State, rect: rl.Rectangle) {
	lua_createtable(L, 0, 6)
	input_idx := lua_gettop(L)

	m := input.mouse_pos()
	lua_pushnumber(L, f64(m.x - rect.x))
	lua_setfield(L, input_idx, "mouse-x")
	lua_pushnumber(L, f64(m.y - rect.y))
	lua_setfield(L, input_idx, "mouse-y")

	mouse_in := m.x >= rect.x && m.x <= rect.x + rect.width &&
	            m.y >= rect.y && m.y <= rect.y + rect.height
	lua_pushboolean(L, mouse_in ? 1 : 0)
	lua_setfield(L, input_idx, "mouse-in")

	push_mouse_buttons(L, input_idx, "mouse-down", input.is_mouse_button_down)
	push_mouse_buttons(L, input_idx, "mouse-pressed", input.is_mouse_button_pressed)
	push_mouse_buttons(L, input_idx, "mouse-released", input.is_mouse_button_released)
}

// ---------------------------------------------------------------------------
// Canvas draw pipeline
// ---------------------------------------------------------------------------

// Call into Fennel canvas._draw, read command buffer, execute Raylib draws
lua_canvas_draw :: proc(b: ^Bridge, name: string, rect: rl.Rectangle) {
	L := b.L

	lua_getglobal(L, "redin_canvas_draw")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		return
	}

	cname := strings.clone_to_cstring(name)
	defer delete(cname)
	lua_pushstring(L, cname)
	lua_pushnumber(L, f64(rect.width))
	lua_pushnumber(L, f64(rect.height))
	push_canvas_input_state(L, rect)

	if lua_pcall(L, 4, 1, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Canvas draw error (%s): %s", name, msg)
		lua_pop(L, 1)
		return
	}

	if lua_istable(L, -1) {
		execute_canvas_commands(L, lua_gettop(L), rect)
	}
	lua_pop(L, 1)
}

execute_canvas_commands :: proc(L: ^Lua_State, buf_idx: i32, rect: rl.Rectangle) {
	rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
	defer rl.EndScissorMode()

	n := i32(lua_objlen(L, buf_idx))
	for i: i32 = 1; i <= n; i += 1 {
		lua_rawgeti(L, buf_idx, i)
		if lua_istable(L, -1) {
			cmd_idx := lua_gettop(L)
			lua_rawgeti(L, cmd_idx, 1)
			if lua_isstring(L, -1) {
				tag := string(lua_tostring_raw(L, -1))
				execute_canvas_command(L, cmd_idx, tag, rect.x, rect.y)
			}
			lua_pop(L, 1) // pop tag
		}
		lua_pop(L, 1) // pop entry
	}
}

execute_canvas_command :: proc(L: ^Lua_State, idx: i32, tag: string, ox: f32, oy: f32) {
	switch tag {
	case "rect":
		x := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y := f32(lua_rawgeti_number(L, idx, 3)) + oy
		w, w_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 4)))
		h, h_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 5)))
		if !w_ok || !h_ok do return
		lua_rawgeti(L, idx, 6)
		opts := lua_gettop(L)

		r := rl.Rectangle{x, y, w, h}
		radius := read_number_field(L, opts, "radius")

		if fill, ok := read_color_field(L, opts, "fill"); ok {
			if radius > 0 {
				roundness := radius / min(w, h) * 2
				rl.DrawRectangleRounded(r, roundness, 6, fill)
			} else {
				rl.DrawRectangleRec(r, fill)
			}
		}
		if stroke, ok := read_color_field(L, opts, "stroke"); ok {
			sw := read_number_field(L, opts, "stroke-width")
			if sw <= 0 do sw = 1
			if radius > 0 {
				roundness := radius / min(w, h) * 2
				rl.DrawRectangleRoundedLinesEx(r, roundness, 6, sw, stroke)
			} else {
				rl.DrawRectangleLinesEx(r, sw, stroke)
			}
		}
		lua_pop(L, 1)

	case "circle":
		cx := f32(lua_rawgeti_number(L, idx, 2)) + ox
		cy := f32(lua_rawgeti_number(L, idx, 3)) + oy
		cr, cr_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 4)))
		if !cr_ok do return
		lua_rawgeti(L, idx, 5)
		opts := lua_gettop(L)

		if fill, ok := read_color_field(L, opts, "fill"); ok {
			rl.DrawCircleV({cx, cy}, cr, fill)
		}
		if stroke, ok := read_color_field(L, opts, "stroke"); ok {
			rl.DrawCircleLinesV({cx, cy}, cr, stroke)
		}
		lua_pop(L, 1)

	case "ellipse":
		cx := f32(lua_rawgeti_number(L, idx, 2)) + ox
		cy := f32(lua_rawgeti_number(L, idx, 3)) + oy
		rx, rx_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 4)))
		ry, ry_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 5)))
		if !rx_ok || !ry_ok do return
		lua_rawgeti(L, idx, 6)
		opts := lua_gettop(L)

		if fill, ok := read_color_field(L, opts, "fill"); ok {
			rl.DrawEllipse(i32(cx), i32(cy), rx, ry, fill)
		}
		if stroke, ok := read_color_field(L, opts, "stroke"); ok {
			rl.DrawEllipseLines(i32(cx), i32(cy), rx, ry, stroke)
		}
		lua_pop(L, 1)

	case "line":
		x1 := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y1 := f32(lua_rawgeti_number(L, idx, 3)) + oy
		x2 := f32(lua_rawgeti_number(L, idx, 4)) + ox
		y2 := f32(lua_rawgeti_number(L, idx, 5)) + oy
		lua_rawgeti(L, idx, 6)
		opts := lua_gettop(L)

		stroke_color: rl.Color
		if s, ok := read_color_field(L, opts, "stroke"); ok {
			stroke_color = s
		} else {
			stroke_color = rl.BLACK
		}
		w := read_number_field(L, opts, "width")
		if w <= 0 do w = 1
		rl.DrawLineEx({x1, y1}, {x2, y2}, w, stroke_color)
		lua_pop(L, 1)

	case "text":
		x := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y := f32(lua_rawgeti_number(L, idx, 3)) + oy
		lua_rawgeti(L, idx, 4)
		// Skip the command instead of feeding nil into DrawTextEx if the
		// table cell isn't a string. Issue #78 finding L3.
		if !lua_isstring(L, -1) {
			lua_pop(L, 1)
			return
		}
		text := lua_tostring_raw(L, -1)
		lua_rawgeti(L, idx, 5)
		opts := lua_gettop(L)

		size := read_number_field(L, opts, "size")
		if size <= 0 do size = 16
		text_color: rl.Color
		if c, ok := read_color_field(L, opts, "color"); ok {
			text_color = c
		} else {
			text_color = rl.BLACK
		}
		font_name := "sans"
		lua_getfield(L, opts, "font")
		if lua_isstring(L, -1) {
			font_name = string(lua_tostring_raw(L, -1))
		}
		lua_pop(L, 1)

		f := font.get(font_name, .Regular)
		spacing := max(size / 10, 1)
		rl.DrawTextEx(f, text, {x, y}, size, spacing, text_color)
		lua_pop(L, 2)

	case "polygon":
		lua_rawgeti(L, idx, 2)
		points_idx := lua_gettop(L)
		lua_rawgeti(L, idx, 3)
		opts := lua_gettop(L)

		if lua_istable(L, points_idx) {
			n_points := i32(lua_objlen(L, points_idx))
			if n_points >= 3 {
				points := make([]rl.Vector2, n_points)
				defer delete(points)
				for p: i32 = 1; p <= n_points; p += 1 {
					lua_rawgeti(L, points_idx, p)
					pt_idx := lua_gettop(L)
					points[p - 1] = {
						f32(lua_rawgeti_number(L, pt_idx, 1)) + ox,
						f32(lua_rawgeti_number(L, pt_idx, 2)) + oy,
					}
					lua_pop(L, 1)
				}

				if fill, ok := read_color_field(L, opts, "fill"); ok {
					for i: i32 = 1; i < n_points - 1; i += 1 {
						rl.DrawTriangle(points[0], points[i], points[i + 1], fill)
					}
				}
				if stroke, ok := read_color_field(L, opts, "stroke"); ok {
					for i: i32 = 0; i < n_points; i += 1 {
						next := (i + 1) % n_points
						rl.DrawLineV(points[i], points[next], stroke)
					}
				}
			}
		}
		lua_pop(L, 2)

	case "image":
		x := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y := f32(lua_rawgeti_number(L, idx, 3)) + oy
		w, w_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 4)))
		h, h_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 5)))
		if !w_ok || !h_ok do return
		rl.DrawRectangleLinesEx({x, y, w, h}, 1, rl.GRAY)
		rl.DrawText("img", i32(x) + 2, i32(y) + 2, 12, rl.GRAY)
	}
}

redin_key_down :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if lua_isstring(L, 1) {
		key := string_to_key(string(lua_tostring_raw(L, 1)))
		lua_pushboolean(L, rl.IsKeyDown(key) ? 1 : 0)
	} else {
		lua_pushboolean(L, 0)
	}
	return 1
}

redin_key_pressed :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if lua_isstring(L, 1) {
		key := string_to_key(string(lua_tostring_raw(L, 1)))
		lua_pushboolean(L, rl.IsKeyPressed(key) ? 1 : 0)
	} else {
		lua_pushboolean(L, 0)
	}
	return 1
}

// Poll HTTP responses and deliver to Lua. Called each frame from main loop.
poll_http :: proc(b: ^Bridge) {
	results: [dynamic]Http_Response
	defer delete(results)
	http_client_poll(&b.http_client, &results)
	for &resp in results {
		deliver_http_response(b, &resp)
		http_response_destroy(&resp)
	}
}

deliver_http_response :: proc(b: ^Bridge, resp: ^Http_Response) {
	L := b.L

	lua_getglobal(L, "redin_events")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		return
	}

	// Build events table with 1 entry: ["http-response", {id, status, body, headers, error}]
	lua_createtable(L, 1, 0)
	lua_createtable(L, 2, 0)

	lua_pushstring(L, "http-response")
	lua_rawseti(L, -2, 1)

	// Response data table
	lua_createtable(L, 0, 5)

	if len(resp.id) > 0 {
		cid := strings.clone_to_cstring(resp.id)
		lua_pushstring(L, cid)
		delete(cid)
		lua_setfield(L, -2, "id")
	}

	lua_pushnumber(L, f64(resp.status))
	lua_setfield(L, -2, "status")

	if len(resp.body) > 0 {
		lua_pushlstring(L, cstring(raw_data(transmute([]u8)resp.body)), uint(len(resp.body)))
		lua_setfield(L, -2, "body")
	}

	if len(resp.error_msg) > 0 {
		cerr := strings.clone_to_cstring(resp.error_msg)
		lua_pushstring(L, cerr)
		delete(cerr)
		lua_setfield(L, -2, "error")
	}

	if len(resp.headers) > 0 {
		lua_createtable(L, 0, i32(len(resp.headers)))
		for k, v in resp.headers {
			ck := strings.clone_to_cstring(k)
			cv := strings.clone_to_cstring(v)
			lua_pushstring(L, cv)
			lua_setfield(L, -2, ck)
			delete(ck)
			delete(cv)
		}
		lua_setfield(L, -2, "headers")
	}

	lua_rawseti(L, -2, 2)
	lua_rawseti(L, -2, 1)

	if lua_pcall(L, 1, 0, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("HTTP response delivery error: %s", msg)
		lua_pop(L, 1)
	}
}

// redin.shell(id, cmd_table, stdin) — queue async shell command
redin_shell :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context
	if g_bridge == nil do return 0

	req: Shell_Request

	if lua_isstring(L, 1) do req.id = strings.clone_from_cstring(lua_tostring_raw(L, 1))

	// Read cmd table (sequential array of strings)
	if lua_istable(L, 2) {
		cmd_idx := i32(2)
		count := int(lua_objlen(L, cmd_idx))
		cmd := make([]string, count)
		for i in 0 ..< count {
			lua_rawgeti(L, cmd_idx, i32(i + 1))
			if lua_isstring(L, -1) {
				cmd[i] = strings.clone_from_cstring(lua_tostring_raw(L, -1))
			}
			lua_pop(L, 1)
		}
		req.cmd = cmd
	}

	if lua_isstring(L, 3) {
		req.stdin = strings.clone_from_cstring(lua_tostring_raw(L, 3))
	} else {
		req.stdin = strings.clone("")
	}

	shell_client_request(&g_bridge.shell_client, req)
	return 0
}

// Poll shell responses and deliver to Lua. Called each frame from main loop.
poll_shell :: proc(b: ^Bridge) {
	results: [dynamic]Shell_Response
	defer delete(results)
	shell_client_poll(&b.shell_client, &results)
	for &resp in results {
		deliver_shell_response(b, &resp)
		shell_response_destroy(&resp)
	}
}

deliver_shell_response :: proc(b: ^Bridge, resp: ^Shell_Response) {
	L := b.L

	lua_getglobal(L, "redin_events")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		return
	}

	// Build events table: [[:shell-response {id, stdout, stderr, exit-code, error}]]
	lua_createtable(L, 1, 0)
	lua_createtable(L, 2, 0)

	lua_pushstring(L, "shell-response")
	lua_rawseti(L, -2, 1)

	// Response data table
	lua_createtable(L, 0, 5)

	if len(resp.id) > 0 {
		cid := strings.clone_to_cstring(resp.id)
		lua_pushstring(L, cid)
		delete(cid)
		lua_setfield(L, -2, "id")
	}

	if len(resp.stdout) > 0 {
		lua_pushlstring(L, cstring(raw_data(transmute([]u8)resp.stdout)), uint(len(resp.stdout)))
		lua_setfield(L, -2, "stdout")
	}

	if len(resp.stderr) > 0 {
		lua_pushlstring(L, cstring(raw_data(transmute([]u8)resp.stderr)), uint(len(resp.stderr)))
		lua_setfield(L, -2, "stderr")
	}

	lua_pushnumber(L, f64(resp.exit_code))
	lua_setfield(L, -2, "exit-code")

	if len(resp.error_msg) > 0 {
		cerr := strings.clone_to_cstring(resp.error_msg)
		lua_pushstring(L, cerr)
		delete(cerr)
		lua_setfield(L, -2, "error")
	}

	lua_rawseti(L, -2, 2)
	lua_rawseti(L, -2, 1)

	if lua_pcall(L, 1, 0, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Shell response delivery error: %s", msg)
		lua_pop(L, 1)
	}
}

// ---------------------------------------------------------------------------
// Lua table → flat parallel arrays (DFS traversal)
// ---------------------------------------------------------------------------

// Parse a :animate attribute table at attrs_idx. Returns the parsed
// decoration on success; the second return is false when the attribute
// is missing or malformed (in which case nothing is stored). The caller
// owns the returned decoration's `provider` string.
parse_animate_attr :: proc(L: ^Lua_State, attrs_idx: i32) -> (types.Animate_Decoration, bool) {
	zero: types.Animate_Decoration
	if attrs_idx <= 0 do return zero, false

	lua_getfield(L, attrs_idx, "animate")
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return zero, false
	a_idx := lua_gettop(L)

	// :provider — required string
	provider: string
	lua_getfield(L, a_idx, "provider")
	if lua_isstring(L, -1) {
		provider = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)
	if len(provider) == 0 {
		fmt.eprintln("animate: missing or non-string :provider, skipping")
		return zero, false
	}

	// :rect — required 5-element vector matching :viewport entries
	rect: types.ViewportRect
	rect_ok := false
	lua_getfield(L, a_idx, "rect")
	if lua_istable(L, -1) {
		r_idx := lua_gettop(L)
		if int(lua_objlen(L, r_idx)) == 5 {
			lua_rawgeti(L, r_idx, 1)
			if lua_isstring(L, -1) {
				rect.anchor = parse_anchor(string(lua_tostring_raw(L, -1)))
			}
			lua_pop(L, 1)
			fields := [4]^types.ViewportValue{&rect.x, &rect.y, &rect.w, &rect.h}
			for j in 0 ..< 4 {
				lua_rawgeti(L, r_idx, i32(j + 2))
				if lua_isnumber(L, -1) {
					fields[j]^ = f32(lua_tonumber(L, -1))
				} else if lua_isstring(L, -1) {
					s := string(lua_tostring_raw(L, -1))
					if s == "full" {
						fields[j]^ = types.SizeValue.FULL
					} else {
						fields[j]^ = parse_fraction(s)
					}
				}
				lua_pop(L, 1)
			}
			rect_ok = true
		}
	}
	lua_pop(L, 1)
	if !rect_ok {
		fmt.eprintln("animate: missing or malformed :rect (must be a 5-element vector), skipping")
		delete(provider)
		return zero, false
	}

	// :z — optional, defaults to .Above
	z := types.Animate_Z.Above
	lua_getfield(L, a_idx, "z")
	if lua_isstring(L, -1) {
		s := string(lua_tostring_raw(L, -1))
		switch s {
		case "above": z = .Above
		case "behind": z = .Behind
		case:
			fmt.eprintfln("animate: unknown :z value %q, defaulting to :above", s)
		}
	}
	lua_pop(L, 1)

	return types.Animate_Decoration{provider = provider, rect = rect, z = z}, true
}

lua_flatten_node :: proc(L: ^Lua_State, index: i32, cur: ^[dynamic]u8, b: ^Bridge, parent_idx: int) {
	abs_idx := index < 0 ? lua_gettop(L) + index + 1 : index
	my_idx := len(b.nodes)

	// Store path
	p := make([]u8, len(cur))
	copy(p, cur[:])
	append(&b.paths, types.Path{value = p, length = u8(len(p))})
	append(&b.parent_indices, parent_idx)
	append(&b.children_list, types.Children{})

	// Position 1: tag (keyword string)
	lua_rawgeti(L, abs_idx, 1)
	tag: string
	if lua_isstring(L, -1) {
		tag = string(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	// Position 2: attrs (table)
	attrs_idx: i32 = 0
	lua_rawgeti(L, abs_idx, 2)
	if lua_istable(L, -1) {
		attrs_idx = lua_gettop(L)
	} else {
		lua_pop(L, 1) // not a table, discard
	}

	// Read text content from position 3 if it's a string
	text_content: string
	lua_rawgeti(L, abs_idx, 3)
	if lua_isstring(L, -1) {
		text_content = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	// Build node based on tag
	node := lua_read_node(L, tag, attrs_idx, text_content)
	append(&b.nodes, node)

	// :animate decoration (idx-aligned with b.nodes). Always append so
	// node_animations stays length-aligned — a missing or malformed
	// entry pushes nil.
	if dec, ok := parse_animate_attr(L, attrs_idx); ok {
		append(&b.node_animations, dec)
	} else {
		append(&b.node_animations, nil)
	}

	// Pop attrs
	if attrs_idx != 0 do lua_pop(L, 1)

	// Position 3+: children (skip string we already read)
	n := i32(lua_objlen(L, abs_idx))
	child_indices: [dynamic]i32
	defer delete(child_indices)

	for i: i32 = 3; i <= n; i += 1 {
		lua_rawgeti(L, abs_idx, i)
		if lua_istable(L, -1) {
			// Check if it's a frame (position 1 is a string tag) or a list of frames
			lua_rawgeti(L, -1, 1)
			if lua_isstring(L, -1) {
				// It's a child frame
				lua_pop(L, 1)
				child_idx := i32(len(b.nodes))
				append(&child_indices, child_idx)
				append(cur, u8(len(child_indices) - 1))
				lua_flatten_node(L, lua_gettop(L), cur, b, my_idx)
				pop(cur)
			} else {
				lua_pop(L, 1)
			}
		}
		lua_pop(L, 1)
	}

	// Store children
	if len(child_indices) > 0 {
		cv := make([]i32, len(child_indices))
		copy(cv, child_indices[:])
		b.children_list[my_idx] = types.Children{value = cv, length = i32(len(child_indices))}
	}
}

lua_read_node :: proc(L: ^Lua_State, tag: string, attrs_idx: i32, text_content: string) -> types.Node {
	switch tag {
	case "stack":
		s: types.NodeStack
		if attrs_idx > 0 {
			lua_getfield(L, attrs_idx, "viewport")
			defer lua_pop(L, 1)
			if lua_istable(L, -1) {
				vp_idx := lua_gettop(L)
				count := int(lua_objlen(L, vp_idx))
				rects := make([]types.ViewportRect, count)
				for i in 0 ..< count {
					lua_rawgeti(L, vp_idx, i32(i + 1))
					if lua_istable(L, -1) {
						rect_idx := lua_gettop(L)
						// Element 1: anchor keyword
						lua_rawgeti(L, rect_idx, 1)
						if lua_isstring(L, -1) {
							rects[i].anchor = parse_anchor(string(lua_tostring_raw(L, -1)))
						}
						lua_pop(L, 1)
						// Elements 2-5: x, y, w, h
						fields := [4]^types.ViewportValue{&rects[i].x, &rects[i].y, &rects[i].w, &rects[i].h}
						for j in 0 ..< 4 {
							lua_rawgeti(L, rect_idx, i32(j + 2))
							if lua_isnumber(L, -1) {
								fields[j]^ = f32(lua_tonumber(L, -1))
							} else if lua_isstring(L, -1) {
								str := string(lua_tostring_raw(L, -1))
								if str == "full" {
									fields[j]^ = types.SizeValue.FULL
								} else {
									fields[j]^ = parse_fraction(str)
								}
							}
							lua_pop(L, 1)
						}
					}
					lua_pop(L, 1)
				}
				s.viewport = rects
			}
		}
		return s

	case "canvas":
		c: types.NodeCanvas
		if attrs_idx > 0 {
			c.provider = lua_get_string_field(L, attrs_idx, "provider")
			c.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			lua_getfield(L, attrs_idx, "width")
			if lua_isstring(L, -1) {
				s := string(lua_tostring_raw(L, -1))
				if s == "full" do c.width = types.SizeValue.FULL
			} else if lua_isnumber(L, -1) {
				c.width = f16(lua_tonumber(L, -1))
			}
			lua_pop(L, 1)
			lua_getfield(L, attrs_idx, "height")
			if lua_isstring(L, -1) {
				s := string(lua_tostring_raw(L, -1))
				if s == "full" do c.height = types.SizeValue.FULL
			} else if lua_isnumber(L, -1) {
				c.height = f16(lua_tonumber(L, -1))
			}
			lua_pop(L, 1)
		}
		return c

	case "vbox":
		v: types.NodeVbox
		if attrs_idx > 0 {
			v.overflow = lua_get_string_field(L, attrs_idx, "overflow")
			v.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			// vbox uses f16 unions — read as f32 then convert
			lua_getfield(L, attrs_idx, "width")
			if lua_isstring(L, -1) {
				s := string(lua_tostring_raw(L, -1))
				if s == "full" do v.width = types.SizeValue.FULL
			} else if lua_isnumber(L, -1) {
				v.width = f16(lua_tonumber(L, -1))
			}
			lua_pop(L, 1)
			lua_getfield(L, attrs_idx, "height")
			if lua_isstring(L, -1) {
				s := string(lua_tostring_raw(L, -1))
				if s == "full" do v.height = types.SizeValue.FULL
			} else if lua_isnumber(L, -1) {
				v.height = f16(lua_tonumber(L, -1))
			}
			lua_pop(L, 1)
			layout := lua_get_string_field_raw(L, attrs_idx, "layout")
			if len(layout) > 0 {
				v.layout = parse_anchor(layout)
			}
			v.draggable = lua_read_draggable(L, attrs_idx)
			v.dropable  = lua_read_dropable (L, attrs_idx)
			v.drag_over = lua_read_drag_over(L, attrs_idx)
			if dh, exists := lua_get_bool_field_opt(L, attrs_idx, "drag-handle"); exists {
				v.drag_handle = dh
			}
		}
		return v

	case "hbox":
		h: types.NodeHbox
		if attrs_idx > 0 {
			h.overflow = lua_get_string_field(L, attrs_idx, "overflow")
			h.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			h.width = lua_get_size_f32(L, attrs_idx, "width")
			h.height = lua_get_size_f32(L, attrs_idx, "height")
			layout := lua_get_string_field_raw(L, attrs_idx, "layout")
			if len(layout) > 0 {
				h.layout = parse_anchor(layout)
			}
			h.draggable = lua_read_draggable(L, attrs_idx)
			h.dropable  = lua_read_dropable (L, attrs_idx)
			h.drag_over = lua_read_drag_over(L, attrs_idx)
			if dh, exists := lua_get_bool_field_opt(L, attrs_idx, "drag-handle"); exists {
				h.drag_handle = dh
			}
		}
		return h

	case "input":
		inp: types.NodeInput
		if attrs_idx > 0 {
			inp.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			inp.change = lua_get_event_name(L, attrs_idx, "change")
			inp.key = lua_get_event_name(L, attrs_idx, "key")
			inp.width = lua_get_size_f32(L, attrs_idx, "width")
			inp.height = lua_get_size_f32(L, attrs_idx, "height")
			inp.value = lua_get_string_field(L, attrs_idx, "value")
			inp.placeholder = lua_get_string_field(L, attrs_idx, "placeholder")
			inp.overflow = lua_get_string_field(L, attrs_idx, "overflow")
		}
		return inp

	case "button":
		btn: types.NodeButton
		if attrs_idx > 0 {
			btn.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			btn.click = lua_get_event_name(L, attrs_idx, "click")
			btn.click_ctx = lua_get_event_ctx(L, attrs_idx, "click")
			btn.width = lua_get_size_f32(L, attrs_idx, "width")
			btn.height = lua_get_size_f32(L, attrs_idx, "height")
			if dh, exists := lua_get_bool_field_opt(L, attrs_idx, "drag-handle"); exists {
				btn.drag_handle = dh
			}
			if btn.drag_handle && len(btn.click) > 0 {
				fmt.eprintln(":button: :drag-handle conflicts with :click — dropping :click")
				delete(btn.click)
				btn.click = ""
				if btn.click_ctx != 0 {
					luaL_unref(L, LUA_REGISTRYINDEX, btn.click_ctx)
					btn.click_ctx = 0
				}
			}
		}
		if len(text_content) > 0 do btn.label = text_content
		return btn

	case "text":
		t: types.NodeText
		if attrs_idx > 0 {
			t.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			t.width = lua_get_size_f32(L, attrs_idx, "width")
			t.height = lua_get_size_f32(L, attrs_idx, "height")
			layout := lua_get_string_field_raw(L, attrs_idx, "layout")
			if len(layout) > 0 {
				t.layout = parse_anchor(layout)
			}
			t.overflow = lua_get_string_field(L, attrs_idx, "overflow")
			// :selectable defaults true; only an explicit false opts out.
			if sel, exists := lua_get_bool_field_opt(L, attrs_idx, "selectable"); exists {
				t.not_selectable = !sel
			}
		}
		if len(text_content) > 0 do t.content = text_content
		return t

	case "image":
		img: types.NodeImage
		if attrs_idx > 0 {
			img.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			img.width = lua_get_size_f32(L, attrs_idx, "width")
			img.height = lua_get_size_f32(L, attrs_idx, "height")
		}
		return img

	case "popout":
		pop: types.NodePopout
		if attrs_idx > 0 {
			pop.aspect = lua_get_string_field(L, attrs_idx, "aspect")
			pop.width = lua_get_size_f32(L, attrs_idx, "width")
			pop.height = lua_get_size_f32(L, attrs_idx, "height")
			pop.x = lua_get_number_field(L, attrs_idx, "x")
			pop.y = lua_get_number_field(L, attrs_idx, "y")
			mode := lua_get_string_field_raw(L, attrs_idx, "mode")
			switch mode {
			case "mouse":
				pop.mode = .MOUSE
			case "fixed":
				pop.mode = .FIXED
			}
		}
		return pop

	case "modal":
		mod: types.NodeModal
		if attrs_idx > 0 {
			mod.aspect = lua_get_string_field(L, attrs_idx, "aspect")
		}
		return mod
	}

	return types.NodeStack{}
}

// Reject any font-face path that could reach outside the project
// directory. `rl.LoadFont` opens and parses the file immediately, so
// an unvalidated path lets a theme source (including PUT /aspects)
// pick any file on disk the redin user can read. Allowed shape:
// relative path, no leading `/`, no `..` segments, no NUL bytes.
// Resolution of the final path is still CWD-relative, matching the
// documented `assets/Font.ttf` pattern in docs/reference/theme.md.
@(private)
validate_font_path :: proc(path: string) -> bool {
	if len(path) == 0 do return false
	if strings.contains_rune(path, 0) do return false
	if path[0] == '/' do return false
	// Segment-wise check so "foo..bar" (a legit filename that happens
	// to contain two dots) doesn't trip the guard, but "../etc/passwd"
	// does. Split on '/' only — Windows support would also need '\\'.
	segments := strings.split(path, "/", context.temp_allocator)
	for seg in segments {
		if seg == ".." do return false
	}
	return true
}

load_font_faces :: proc(L: ^Lua_State, index: i32) {
	lua_pushnil(L)
	for lua_next(L, index) != 0 {
		if lua_isstring(L, -2) && lua_istable(L, -1) {
			font_name := string(lua_tostring_raw(L, -2))
			variants_idx := lua_gettop(L)

			style_keys := [?]struct{key: cstring, style: font.Font_Style}{
				{"regular", .Regular},
				{"bold", .Bold},
				{"italic", .Italic},
			}

			for sk in style_keys {
				lua_getfield(L, variants_idx, sk.key)
				if lua_isstring(L, -1) {
					path := string(lua_tostring_raw(L, -1))
					if !validate_font_path(path) {
						fmt.eprintfln("Rejected font path (must be relative, no ..): %s", path)
						lua_pop(L, 1)
						continue
					}
					cpath := strings.clone_to_cstring(path, context.temp_allocator)
					loaded := rl.LoadFont(cpath)
					if loaded.texture.id > 0 {
						font.register(strings.clone(font_name), sk.style, loaded)
					} else {
						fmt.eprintfln("Failed to load font: %s", path)
					}
				}
				lua_pop(L, 1)
			}
		}
		lua_pop(L, 1)
	}
}

// ---------------------------------------------------------------------------
// Lua table → theme
// ---------------------------------------------------------------------------

lua_to_theme :: proc(L: ^Lua_State, index: i32) -> map[string]types.Theme {
	theme := make(map[string]types.Theme)
	abs_idx := index < 0 ? lua_gettop(L) + index + 1 : index

	lua_pushnil(L)
	for lua_next(L, abs_idx) != 0 {
		if lua_isstring(L, -2) && lua_istable(L, -1) {
			key := strings.clone_from_cstring(lua_tostring_raw(L, -2))
			if key == "font-face" {
				delete(key)
				lua_pop(L, 1)
				continue
			}
			t: types.Theme
			props_idx := lua_gettop(L)

			t.bg = lua_get_rgb_field(L, props_idx, "bg")
			t.color = lua_get_rgb_field(L, props_idx, "color")
			t.border = lua_get_rgb_field(L, props_idx, "border")
			t.padding = lua_get_padding_field(L, props_idx, "padding")
			t.border_width = u8(lua_get_number_field(L, props_idx, "border-width"))
			t.radius = u8(lua_get_number_field(L, props_idx, "radius"))
			t.font_size = f16(lua_get_number_field(L, props_idx, "font-size"))
			t.line_height = lua_get_number_field(L, props_idx, "line-height")
			t.font = lua_get_string_field(L, props_idx, "font")
			t.opacity = lua_get_number_field(L, props_idx, "opacity")
			t.shadow = lua_get_shadow_field(L, props_idx, "shadow")
			t.selection = lua_get_rgba_field(L, props_idx, "selection")

			lua_getfield(L, props_idx, "weight")
			if lua_isnumber(L, -1) {
				t.weight = u8(lua_tonumber(L, -1))
			} else if lua_isstring(L, -1) {
				w := string(lua_tostring_raw(L, -1))
				if w == "bold" do t.weight = 1
				else if w == "italic" do t.weight = 2
			}
			lua_pop(L, 1)

			lua_getfield(L, props_idx, "text-align")
			if lua_isstring(L, -1) {
				v := string(lua_tostring_raw(L, -1))
				switch v {
				case "top":    t.text_align = .Top
				case "center": t.text_align = .Center
				case "bottom": t.text_align = .Bottom
				}
			}
			lua_pop(L, 1)

			theme[key] = t
		}
		lua_pop(L, 1)
	}

	return theme
}

lua_get_rgba_field :: proc(L: ^Lua_State, index: i32, field: cstring) -> [4]u8 {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}
	abs := lua_gettop(L)
	out: [4]u8
	for i in 0 ..< 4 {
		lua_rawgeti(L, abs, i32(i + 1))
		out[i] = u8(lua_tonumber(L, -1))
		lua_pop(L, 1)
	}
	return out
}

lua_get_rgb_field :: proc(L: ^Lua_State, index: i32, field: cstring) -> [3]u8 {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}
	abs := lua_gettop(L)
	lua_rawgeti(L, abs, 1)
	r := u8(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_rawgeti(L, abs, 2)
	g := u8(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_rawgeti(L, abs, 3)
	b := u8(lua_tonumber(L, -1))
	lua_pop(L, 1)
	return {r, g, b}
}

// Shadow format: [x y blur [r g b a]]
lua_get_shadow_field :: proc(L: ^Lua_State, index: i32, field: cstring) -> types.Shadow {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}
	abs := lua_gettop(L)
	s: types.Shadow
	lua_rawgeti(L, abs, 1)
	s.x = f32(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_rawgeti(L, abs, 2)
	s.y = f32(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_rawgeti(L, abs, 3)
	s.blur = f32(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_rawgeti(L, abs, 4)
	if lua_istable(L, -1) {
		col_idx := lua_gettop(L)
		lua_rawgeti(L, col_idx, 1)
		s.color[0] = u8(lua_tonumber(L, -1))
		lua_pop(L, 1)
		lua_rawgeti(L, col_idx, 2)
		s.color[1] = u8(lua_tonumber(L, -1))
		lua_pop(L, 1)
		lua_rawgeti(L, col_idx, 3)
		s.color[2] = u8(lua_tonumber(L, -1))
		lua_pop(L, 1)
		lua_rawgeti(L, col_idx, 4)
		s.color[3] = u8(lua_tonumber(L, -1))
		lua_pop(L, 1)
	}
	lua_pop(L, 1)
	return s
}

lua_get_padding_field :: proc(L: ^Lua_State, index: i32, field: cstring) -> [4]u8 {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}
	abs := lua_gettop(L)
	vals: [4]u8
	for i: i32 = 0; i < 4; i += 1 {
		lua_rawgeti(L, abs, i + 1)
		vals[i] = u8(lua_tonumber(L, -1))
		lua_pop(L, 1)
	}
	return vals
}

// ---------------------------------------------------------------------------
// Event delivery to Lua
// ---------------------------------------------------------------------------

deliver_events :: proc(b: ^Bridge, events: []types.InputEvent) {
	if len(events) == 0 do return
	L := b.L

	lua_getglobal(L, "redin_events")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		return
	}

	lua_createtable(L, i32(len(events)), 0)
	lua_idx: i32 = 0
	for event in events {
		if _, is_scroll := event.(types.ScrollEvent); is_scroll do continue
		push_input_event_as_lua(L, event)
		lua_idx += 1
		lua_rawseti(L, -2, lua_idx)
	}
	if lua_idx == 0 {
		lua_pop(L, 2) // pop empty table and redin_events
		return
	}

	if lua_pcall(L, 1, 0, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Event delivery error: %s", msg)
		lua_pop(L, 1)
	}
}

// Deliver input dispatch events to Fennel.
// Each event is wrapped as [:dispatch [:event-name {context}]].
deliver_dispatch_events :: proc(b: ^Bridge, events: []types.Dispatch_Event) {
	if len(events) == 0 do return
	L := b.L

	for event in events {
		lua_getglobal(L, "redin_events")
		if lua_isnil(L, -1) {
			lua_pop(L, 1)
			return
		}

		// Build events table with 1 entry
		lua_createtable(L, 1, 0)

		switch e in event {
		case types.Change_Event:
			// [:dispatch [:event-name {:value "text"}]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			// Inner event: [:event-name {:value "text"}]
			lua_createtable(L, 2, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			// Context table: {:value "text"}
			lua_createtable(L, 0, 1)
			val := strings.clone_to_cstring(e.value, context.temp_allocator)
			lua_pushstring(L, val)
			lua_setfield(L, -2, "value")
			lua_rawseti(L, -2, 2)

			lua_rawseti(L, -2, 2) // set dispatch wrapper as event[2]
			lua_rawseti(L, -2, 1) // set as events[1]

		case types.Click_Event:
			// [:dispatch [:event-name context?]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			// Inner event: [:event-name] or [:event-name context]
			inner_len: i32 = 1
			if e.context_ref != 0 do inner_len = 2
			lua_createtable(L, inner_len, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			if e.context_ref != 0 {
				lua_rawgeti(L, LUA_REGISTRYINDEX, e.context_ref)
				lua_rawseti(L, -2, 2)
			}

			lua_rawseti(L, -2, 2) // set dispatch wrapper as event[2]
			lua_rawseti(L, -2, 1) // set as events[1]

		case types.Key_Event_Dispatch:
			// [:dispatch [:event-name {:key "enter" :mods {:shift false ...}}]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			// Inner event
			lua_createtable(L, 2, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			// Context table: {:key "enter" :mods {...}}
			lua_createtable(L, 0, 2)
			key_name := strings.clone_to_cstring(e.key, context.temp_allocator)
			lua_pushstring(L, key_name)
			lua_setfield(L, -2, "key")

			// Mods subtable
			lua_createtable(L, 0, 4)
			lua_pushboolean(L, e.mods.shift ? 1 : 0)
			lua_setfield(L, -2, "shift")
			lua_pushboolean(L, e.mods.ctrl ? 1 : 0)
			lua_setfield(L, -2, "ctrl")
			lua_pushboolean(L, e.mods.alt ? 1 : 0)
			lua_setfield(L, -2, "alt")
			lua_pushboolean(L, e.mods.super ? 1 : 0)
			lua_setfield(L, -2, "super")
			lua_setfield(L, -2, "mods")

			lua_rawseti(L, -2, 2) // set dispatch wrapper as event[2]
			lua_rawseti(L, -2, 1) // set as events[1]

		case types.Drag_Event:
			// [:dispatch [:event-name {:value payload}]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			lua_createtable(L, 2, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			// Context: {:value payload}
			lua_createtable(L, 0, 1)
			if e.context_ref != 0 {
				lua_rawgeti(L, LUA_REGISTRYINDEX, e.context_ref)
			} else {
				lua_pushnil(L)
			}
			lua_setfield(L, -2, "value")
			lua_rawseti(L, -2, 2)

			lua_rawseti(L, -2, 2)
			lua_rawseti(L, -2, 1)

		case types.Drop_Event:
			// [:dispatch [:event-name {:from source-payload :to target-payload}]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			lua_createtable(L, 2, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			// Context: {:from source :to target}
			lua_createtable(L, 0, 2)
			if e.from_ref != 0 {
				lua_rawgeti(L, LUA_REGISTRYINDEX, e.from_ref)
			} else {
				lua_pushnil(L)
			}
			lua_setfield(L, -2, "from")
			if e.to_ref != 0 {
				lua_rawgeti(L, LUA_REGISTRYINDEX, e.to_ref)
			} else {
				lua_pushnil(L)
			}
			lua_setfield(L, -2, "to")
			lua_rawseti(L, -2, 2)

			lua_rawseti(L, -2, 2)
			lua_rawseti(L, -2, 1)

		case types.Drag_Over_Event:
			// [:dispatch [:event-name {:phase :enter|:leave}]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			lua_createtable(L, 2, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			// {:phase :enter} or {:phase :leave}
			lua_createtable(L, 0, 1)
			phase: cstring = e.phase == .Enter ? "enter" : "leave"
			lua_pushstring(L, phase)
			lua_setfield(L, -2, "phase")
			lua_rawseti(L, -2, 2)

			lua_rawseti(L, -2, 2)
			lua_rawseti(L, -2, 1)
		}

		if lua_pcall(L, 1, 0, 0) != 0 {
			msg := lua_tostring_raw(L, -1)
			fmt.eprintfln("Dispatch event delivery error: %s", msg)
			lua_pop(L, 1)
		}
	}
}

render_tick :: proc(b: ^Bridge) {
	L := b.L
	b.frame_changed = false

	lua_getglobal(L, "redin_render_tick")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		return
	}

	if lua_pcall(L, 0, 0, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Render tick error: %s", msg)
		lua_pop(L, 1)
	}
}

poll_timers :: proc(b: ^Bridge) {
	L := b.L

	lua_getglobal(L, "redin_poll_timers")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		return
	}

	t := time.now()
	ms := f64(time.to_unix_nanoseconds(t)) / 1e6
	lua_pushnumber(L, ms)

	if lua_pcall(L, 1, 1, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Timer poll error: %s", msg)
		lua_pop(L, 1)
	} else {
		lua_pop(L, 1)
	}
}

push_input_event_as_lua :: proc(L: ^Lua_State, event: types.InputEvent) {
	switch e in event {
	case types.MouseEvent:
		lua_createtable(L, 3, 0)
		lua_pushstring(L, "click")
		lua_rawseti(L, -2, 1)
		lua_pushnumber(L, f64(e.x))
		lua_rawseti(L, -2, 2)
		lua_pushnumber(L, f64(e.y))
		lua_rawseti(L, -2, 3)

	case types.KeyEvent:
		lua_createtable(L, 3, 0)
		lua_pushstring(L, "key")
		lua_rawseti(L, -2, 1)
		lua_pushstring(L, key_to_string(e.key))
		lua_rawseti(L, -2, 2)
		lua_createtable(L, 0, 4)
		lua_pushboolean(L, e.mods.shift ? 1 : 0)
		lua_setfield(L, -2, "shift")
		lua_pushboolean(L, e.mods.ctrl ? 1 : 0)
		lua_setfield(L, -2, "ctrl")
		lua_pushboolean(L, e.mods.alt ? 1 : 0)
		lua_setfield(L, -2, "alt")
		lua_pushboolean(L, e.mods.super ? 1 : 0)
		lua_setfield(L, -2, "super")
		lua_rawseti(L, -2, 3)

	case types.CharEvent:
		lua_createtable(L, 2, 0)
		lua_pushstring(L, "char")
		lua_rawseti(L, -2, 1)
		buf, n := utf8.encode_rune(e.char)
		lua_pushlstring(L, cstring(raw_data(buf[:])), uint(n))
		lua_rawseti(L, -2, 2)

	case types.ScrollEvent:
		// handled by render scroll state
	case types.ResizeEvent:
		lua_createtable(L, 3, 0)
		lua_pushstring(L, "resize")
		lua_rawseti(L, -2, 1)
		lua_pushnumber(L, f64(rl.GetScreenWidth()))
		lua_rawseti(L, -2, 2)
		lua_pushnumber(L, f64(rl.GetScreenHeight()))
		lua_rawseti(L, -2, 3)
	}
}

parse_anchor :: proc(s: string) -> types.Anchor {
	switch s {
	case "top_left":      return .TOP_LEFT
	case "top_center":    return .TOP_CENTER
	case "top_right":     return .TOP_RIGHT
	case "center_left":   return .CENTER_LEFT
	case "center":        return .CENTER
	case "center_right":  return .CENTER_RIGHT
	case "bottom_left":   return .BOTTOM_LEFT
	case "bottom_center": return .BOTTOM_CENTER
	case "bottom_right":  return .BOTTOM_RIGHT
	case:
		fmt.eprintfln("viewport: unrecognized anchor '%s', defaulting to top_left", s)
		return .TOP_LEFT
	}
}

// Parse a fraction string like "1_2" -> Fraction{1, 2}, "3_4" -> Fraction{3, 4}.
// Numerator and denominator must fit in u8 (0-255).
parse_fraction :: proc(s: string) -> types.ViewportValue {
	for i in 0 ..< len(s) {
		if s[i] == '_' && i > 0 && i < len(s) - 1 {
			num: uint = 0
			den: uint = 0
			ok := true
			for j in 0 ..< i {
				d := s[j]
				if d < '0' || d > '9' { ok = false; break }
				num = num * 10 + uint(d - '0')
			}
			if ok {
				for j in i + 1 ..< len(s) {
					d := s[j]
					if d < '0' || d > '9' { ok = false; break }
					den = den * 10 + uint(d - '0')
				}
			}
			if ok && den > 0 && num <= 255 && den <= 255 {
				return types.Fraction{u8(num), u8(den)}
			}
		}
	}
	fmt.eprintfln("viewport: unrecognized value '%s'", s)
	return types.Fraction{0, 0}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Init-only helper: assumes the redin table is at stack -2 and adds a
// cfield to it. The public, post-init API for adding cfuncs to the redin
// table lives in api.odin (`register_cfunc` / `register_cfunc_raw`); that
// version locates the redin table via lua_getglobal so it works after init
// returns.
@(private)
register_cfunc_init :: proc(L: ^Lua_State, name: cstring, f: Lua_CFunction) {
	lua_pushcfunction(L, f)
	lua_setfield(L, -2, name)
}

lua_get_string_field :: proc(L: ^Lua_State, index: i32, field: cstring) -> string {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_isstring(L, -1) {
		return strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	return ""
}

// Read an event vector field: [:event-name] -> "event-name"
// Falls back to plain string if the field is a string.
lua_get_event_name :: proc(L: ^Lua_State, index: i32, field: cstring) -> string {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_isstring(L, -1) {
		return strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	if lua_istable(L, -1) {
		lua_rawgeti(L, -1, 1)
		defer lua_pop(L, 1)
		if lua_isstring(L, -1) {
			return strings.clone_from_cstring(lua_tostring_raw(L, -1))
		}
	}
	return ""
}

// Read element 2 of an event vector field and store as a Lua registry ref.
// Returns 0 if there is no context.
lua_get_event_ctx :: proc(L: ^Lua_State, index: i32, field: cstring) -> i32 {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_istable(L, -1) {
		lua_rawgeti(L, -1, 2)
		if !lua_isnil(L, -1) {
			return luaL_ref(L, LUA_REGISTRYINDEX) // pops value, returns ref
		}
		lua_pop(L, 1)
	}
	return 0
}

lua_get_string_field_raw :: proc(L: ^Lua_State, index: i32, field: cstring) -> string {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_isstring(L, -1) {
		return string(lua_tostring_raw(L, -1))
	}
	return ""
}

lua_get_size_f32 :: proc(L: ^Lua_State, index: i32, field: cstring) -> union {types.SizeValue, f32} {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_isstring(L, -1) {
		s := string(lua_tostring_raw(L, -1))
		if s == "full" do return types.SizeValue.FULL
	} else if lua_isnumber(L, -1) {
		return f32(lua_tonumber(L, -1))
	}
	return nil
}

lua_get_number_field :: proc(L: ^Lua_State, index: i32, field: cstring) -> f32 {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_isnumber(L, -1) {
		return f32(lua_tonumber(L, -1))
	}
	return 0
}

// Reads slot at `slot_idx` of the table at `tbl_idx` as a tag list:
//   - a string keyword → one-element slice
//   - a Lua array of strings → cloned multi-element slice
//   - anything else → empty slice
// Returned strings are heap-cloned and owned by the caller (freed by
// clear_node_strings via Drag_Attrs cleanup).
lua_read_tags :: proc(L: ^Lua_State, tbl_idx: i32, slot_idx: i32) -> []string {
    lua_rawgeti(L, tbl_idx, slot_idx)
    defer lua_pop(L, 1)

    if lua_isstring(L, -1) {
        out := make([]string, 1)
        out[0] = strings.clone_from_cstring(lua_tostring_raw(L, -1))
        return out
    }

    if lua_istable(L, -1) {
        n := int(lua_objlen(L, -1))
        if n == 0 do return nil
        list_idx := lua_gettop(L)
        tmp: [dynamic]string
        defer delete(tmp)
        for i in 1..=n {
            lua_rawgeti(L, list_idx, i32(i))
            if lua_isstring(L, -1) {
                append(&tmp, strings.clone_from_cstring(lua_tostring_raw(L, -1)))
            }
            lua_pop(L, 1)
        }
        if len(tmp) == 0 do return nil
        out := make([]string, len(tmp))
        copy(out, tmp[:])
        return out
    }

    return nil
}

// Parse `:draggable [tags {options} payload]`. Populates the drag_* fields
// of `out`. On error, fields stay zero and an error is logged.
lua_read_draggable :: proc(L: ^Lua_State, attrs_idx: i32) -> Maybe(types.Draggable_Attrs) {
	if attrs_idx <= 0 do return nil
	lua_getfield(L, attrs_idx, "draggable")
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return nil
	tbl := lua_gettop(L)

	// Slot 1 — tags
	tags := lua_read_tags(L, tbl, 1)
	if len(tags) == 0 {
		fmt.eprintln(":draggable: missing or empty tag list, skipping")
		return nil
	}

	// Slot 2 — options table
	lua_rawgeti(L, tbl, 2)
	if !lua_istable(L, -1) {
		lua_pop(L, 1)
		fmt.eprintln(":draggable: expected options table at slot 2, skipping")
		for s in tags do delete(s)
		delete(tags)
		return nil
	}
	opts := lua_gettop(L)

	out: types.Draggable_Attrs
	out.tags = tags

	// :event (required)
	lua_getfield(L, opts, "event")
	if lua_isstring(L, -1) {
		out.event = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)
	if len(out.event) == 0 {
		fmt.eprintln(":draggable: missing :event in options, skipping")
		lua_pop(L, 1)  // pop opts
		for s in out.tags do delete(s)
		delete(out.tags)
		return nil
	}

	// :mode (optional, default Preview)
	lua_getfield(L, opts, "mode")
	if lua_isstring(L, -1) {
		s := string(lua_tostring_raw(L, -1))
		switch s {
		case "preview": out.mode = .Preview
		case "none":    out.mode = .None
		case:           fmt.eprintfln(":draggable: unknown :mode %q, defaulting to :preview", s)
		}
	}
	lua_pop(L, 1)

	// :aspect (optional)
	lua_getfield(L, opts, "aspect")
	if lua_isstring(L, -1) {
		out.aspect = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	// :handle (optional, default true). Only an explicit `false` disables
	// container-as-grab-surface; descendants marked :drag-handle become the
	// only grab targets. Validated later by validate_drag_handles.
	lua_getfield(L, opts, "handle")
	if lua_isboolean(L, -1) {
		if lua_toboolean(L, -1) == 0 do out.handle_off = true
	}
	lua_pop(L, 1)

	// :animate (optional, reuse parse_animate_attr against the options table)
	if dec, ok := parse_animate_attr(L, opts); ok {
		out.animate = dec
	}

	lua_pop(L, 1)  // pop opts

	// Slot 3 — payload (any Lua value, stored as registry ref)
	lua_rawgeti(L, tbl, 3)
	if !lua_isnil(L, -1) {
		out.ctx = luaL_ref(L, LUA_REGISTRYINDEX)  // pops value
	} else {
		lua_pop(L, 1)
	}

	return out
}

// Parse `:dropable [tags {options} payload]`.
lua_read_dropable :: proc(L: ^Lua_State, attrs_idx: i32) -> Maybe(types.Dropable_Attrs) {
	if attrs_idx <= 0 do return nil
	lua_getfield(L, attrs_idx, "dropable")
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return nil
	tbl := lua_gettop(L)

	tags := lua_read_tags(L, tbl, 1)
	if len(tags) == 0 {
		fmt.eprintln(":dropable: missing or empty tag list, skipping")
		return nil
	}

	lua_rawgeti(L, tbl, 2)
	if !lua_istable(L, -1) {
		lua_pop(L, 1)
		fmt.eprintln(":dropable: expected options table at slot 2, skipping")
		for s in tags do delete(s)
		delete(tags)
		return nil
	}
	opts := lua_gettop(L)

	out: types.Dropable_Attrs
	out.tags = tags

	lua_getfield(L, opts, "event")
	if lua_isstring(L, -1) {
		out.event = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)
	if len(out.event) == 0 {
		fmt.eprintln(":dropable: missing :event in options, skipping")
		lua_pop(L, 1)
		for s in out.tags do delete(s)
		delete(out.tags)
		return nil
	}

	lua_getfield(L, opts, "aspect")
	if lua_isstring(L, -1) {
		out.aspect = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	if dec, ok := parse_animate_attr(L, opts); ok {
		out.animate = dec
	}

	lua_pop(L, 1)

	lua_rawgeti(L, tbl, 3)
	if !lua_isnil(L, -1) {
		out.ctx = luaL_ref(L, LUA_REGISTRYINDEX)
	} else {
		lua_pop(L, 1)
	}

	return out
}

// Parse `:drag-over [tags {options}]` (no payload slot).
lua_read_drag_over :: proc(L: ^Lua_State, attrs_idx: i32) -> Maybe(types.Drag_Over_Attrs) {
	if attrs_idx <= 0 do return nil
	lua_getfield(L, attrs_idx, "drag-over")
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return nil
	tbl := lua_gettop(L)

	tags := lua_read_tags(L, tbl, 1)
	if len(tags) == 0 {
		fmt.eprintln(":drag-over: missing or empty tag list, skipping")
		return nil
	}

	lua_rawgeti(L, tbl, 2)
	if !lua_istable(L, -1) {
		lua_pop(L, 1)
		for s in tags do delete(s)
		delete(tags)
		return nil
	}
	opts := lua_gettop(L)

	out: types.Drag_Over_Attrs
	out.tags = tags

	// :event is OPTIONAL on :drag-over (visual-only zones don't need a handler)
	lua_getfield(L, opts, "event")
	if lua_isstring(L, -1) {
		out.event = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	lua_getfield(L, opts, "aspect")
	if lua_isstring(L, -1) {
		out.aspect = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	if dec, ok := parse_animate_attr(L, opts); ok {
		out.animate = dec
	}

	lua_pop(L, 1)

	return out
}


// Read an optional boolean field. Returns (value, true) when the field exists
// and is a boolean, (false, false) otherwise. Callers use the existence flag to
// distinguish "absent" from an explicit false.
lua_get_bool_field_opt :: proc(L: ^Lua_State, index: i32, field: cstring) -> (value: bool, exists: bool) {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_type(L, -1) == LUA_TBOOLEAN {
		return lua_toboolean(L, -1) != 0, true
	}
	return false, false
}

key_to_string :: proc(key: rl.KeyboardKey) -> cstring {
	#partial switch key {
	case .ENTER:     return "enter"
	case .ESCAPE:    return "escape"
	case .BACKSPACE: return "backspace"
	case .TAB:       return "tab"
	case .SPACE:     return "space"
	case .UP:        return "up"
	case .DOWN:      return "down"
	case .LEFT:      return "left"
	case .RIGHT:     return "right"
	case .DELETE:    return "delete"
	case .HOME:      return "home"
	case .END:       return "end"
	case .PAGE_UP:   return "pageup"
	case .PAGE_DOWN: return "pagedown"
	case .INSERT:    return "insert"
	case .F1:        return "f1"
	case .F2:        return "f2"
	case .F3:        return "f3"
	case .F4:        return "f4"
	case .F5:        return "f5"
	case .F6:        return "f6"
	case .F7:        return "f7"
	case .F8:        return "f8"
	case .F9:        return "f9"
	case .F10:       return "f10"
	case .F11:       return "f11"
	case .F12:       return "f12"
	case .A:         return "a"
	case .B:         return "b"
	case .C:         return "c"
	case .D:         return "d"
	case .E:         return "e"
	case .F:         return "f"
	case .G:         return "g"
	case .H:         return "h"
	case .I:         return "i"
	case .J:         return "j"
	case .K:         return "k"
	case .L:         return "l"
	case .M:         return "m"
	case .N:         return "n"
	case .O:         return "o"
	case .P:         return "p"
	case .Q:         return "q"
	case .R:         return "r"
	case .S:         return "s"
	case .T:         return "t"
	case .U:         return "u"
	case .V:         return "v"
	case .W:         return "w"
	case .X:         return "x"
	case .Y:         return "y"
	case .Z:         return "z"
	case .ZERO:      return "0"
	case .ONE:       return "1"
	case .TWO:       return "2"
	case .THREE:     return "3"
	case .FOUR:      return "4"
	case .FIVE:      return "5"
	case .SIX:       return "6"
	case .SEVEN:     return "7"
	case .EIGHT:     return "8"
	case .NINE:      return "9"
	case:            return "unknown"
	}
}

string_to_key :: proc(name: string) -> rl.KeyboardKey {
	switch name {
	case "enter":     return .ENTER
	case "escape":    return .ESCAPE
	case "backspace": return .BACKSPACE
	case "tab":       return .TAB
	case "space":     return .SPACE
	case "up":        return .UP
	case "down":      return .DOWN
	case "left":      return .LEFT
	case "right":     return .RIGHT
	case "delete":    return .DELETE
	case "home":      return .HOME
	case "end":       return .END
	case "pageup":    return .PAGE_UP
	case "pagedown":  return .PAGE_DOWN
	case "insert":    return .INSERT
	case "f1":        return .F1
	case "f2":        return .F2
	case "f3":        return .F3
	case "f4":        return .F4
	case "f5":        return .F5
	case "f6":        return .F6
	case "f7":        return .F7
	case "f8":        return .F8
	case "f9":        return .F9
	case "f10":       return .F10
	case "f11":       return .F11
	case "f12":       return .F12
	case "a":         return .A
	case "b":         return .B
	case "c":         return .C
	case "d":         return .D
	case "e":         return .E
	case "f":         return .F
	case "g":         return .G
	case "h":         return .H
	case "i":         return .I
	case "j":         return .J
	case "k":         return .K
	case "l":         return .L
	case "m":         return .M
	case "n":         return .N
	case "o":         return .O
	case "p":         return .P
	case "q":         return .Q
	case "r":         return .R
	case "s":         return .S
	case "t":         return .T
	case "u":         return .U
	case "v":         return .V
	case "w":         return .W
	case "x":         return .X
	case "y":         return .Y
	case "z":         return .Z
	case "0":         return .ZERO
	case "1":         return .ONE
	case "2":         return .TWO
	case "3":         return .THREE
	case "4":         return .FOUR
	case "5":         return .FIVE
	case "6":         return .SIX
	case "7":         return .SEVEN
	case "8":         return .EIGHT
	case "9":         return .NINE
	case "shift":     return .LEFT_SHIFT
	case "ctrl":      return .LEFT_CONTROL
	case "alt":       return .LEFT_ALT
	case:             return .KEY_NULL
	}
}

setup_lua_paths :: proc(L: ^Lua_State) {
	// Search paths, in priority order:
	//   <exe>/...          — pinned release (binary sits next to vendor/+runtime/)
	//   <exe>/../.redin/... — redin-cli's upgrade-to-native layout (build/redin's
	//                         sibling is .redin/, which has vendor/ + runtime/)
	//   vendor/fennel/...  — cwd-relative (running from the redin repo in dev)
	code := `
		local d = _redin_exe_dir
		package.path =
		  d .. "/vendor/fennel/?.lua;" ..
		  d .. "/runtime/?.lua;" ..
		  d .. "/../.redin/vendor/fennel/?.lua;" ..
		  d .. "/../.redin/runtime/?.lua;" ..
		  "vendor/fennel/?.lua;" ..
		  package.path
	`
	luaL_dostring(L, cstring(raw_data(code)))
}

load_fennel :: proc(L: ^Lua_State) {
	code := `
		local d = _redin_exe_dir
		package.loaded["fennel"] = {}
		local ok = pcall(dofile, d .. "/vendor/fennel/fennel.lua")
		if not ok then ok = pcall(dofile, d .. "/../.redin/vendor/fennel/fennel.lua") end
		if not ok then pcall(dofile, "vendor/fennel/fennel.lua") end
		package.loaded["fennel"] = nil
		local fennel = require("fennel")
		table.insert(package.loaders, fennel.searcher)
		fennel.path =
		  d .. "/runtime/?.fnl;" ..
		  d .. "/../.redin/runtime/?.fnl;" ..
		  "src/runtime/?.fnl;" ..
		  fennel.path
	`
	if luaL_dostring(L, cstring(raw_data(code))) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Error loading Fennel: %s", msg)
		lua_pop(L, 1)
	}
}

load_runtime :: proc(L: ^Lua_State) {
	code := `require("init")`
	if luaL_dostring(L, cstring(raw_data(code))) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Error loading runtime: %s", msg)
		lua_pop(L, 1)
	}
}
