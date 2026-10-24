package bridge

import "core:testing"

// Review C2: execute_canvas_commands runs *after* the provider's pcall
// returned, i.e. unprotected. It indexed opts / polygon vertices without
// checking they were tables, so `(ctx.rect 0 0 10 10 5)` (number opts)
// raised an unprotected Lua error (LuaJIT PANIC, exit 1) and
// `(ctx.polygon [0 0 10 0 5 10])` (flat point list) segfaulted in
// lua_rawgeti on a number. These tests cover the parse half of the
// executor (no raylib draw calls, so no GL context needed).

@(private = "file")
push_lua :: proc(t: ^testing.T, L: ^Lua_State, code: cstring) -> i32 {
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "lua setup failed (rc=%d)", rc)
	return lua_gettop(L)
}

@(test)
test_canvas_opts_non_table_becomes_empty_table :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// A command whose opts slot (6) holds a number, a string, a boolean,
	// a table with a throwing __index, and nothing at all.
	cases := []cstring{
		`return {"rect", 0, 0, 10, 10, 5}`,
		`return {"rect", 0, 0, 10, 10, "red"}`,
		`return {"rect", 0, 0, 10, 10, true}`,
		`return {"rect", 0, 0, 10, 10, setmetatable({}, {__index = function() error("boom") end})}`,
		`return {"rect", 0, 0, 10, 10}`,
	}
	for c in cases {
		cmd := push_lua(t, L, c)
		top := lua_gettop(L)
		opts := canvas_opts(L, cmd, 6)
		testing.expect(t, lua_istable(L, opts), "canvas_opts must leave a table")
		testing.expect_value(t, lua_gettop(L), top + 1)
		_, has_fill := read_color_field(L, opts, "fill")
		testing.expect(t, !has_fill, "no fill expected")
		testing.expect_value(t, read_number_field(L, opts, "radius"), f32(0))
		lua_settop(L, 0)
	}
}

@(test)
test_canvas_opts_table_passes_through :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	cmd := push_lua(t, L, `return {"rect", 0, 0, 10, 10, {fill = {1, 2, 3}, radius = 4}}`)
	opts := canvas_opts(L, cmd, 6)
	c, ok := read_color_field(L, opts, "fill")
	testing.expect(t, ok)
	testing.expect_value(t, c.r, u8(1))
	testing.expect_value(t, c.b, u8(3))
	testing.expect_value(t, read_number_field(L, opts, "radius"), f32(4))
	testing.expect_value(t, lua_gettop(L), cmd + 1)
}

@(test)
test_read_fields_on_non_table_are_safe :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	lua_pushnumber(L, 5)
	idx := lua_gettop(L)
	_, ok := read_color_field(L, idx, "fill")
	testing.expect(t, !ok)
	testing.expect_value(t, read_number_field(L, idx, "radius"), f32(0))
	testing.expect_value(t, lua_gettop(L), idx)
}

@(test)
test_polygon_flat_point_list_is_rejected :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	pts := push_lua(t, L, `return {0, 0, 10, 0, 5, 10}`)
	points, ok := read_polygon_points(L, pts, 0, 0)
	defer delete(points)
	testing.expect(t, !ok, "flat list (number vertices) must be rejected")
	testing.expect_value(t, lua_gettop(L), pts)
}

@(test)
test_polygon_mixed_vertices_are_rejected :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	pts := push_lua(t, L, `return {{0, 0}, "x", {5, 10}}`)
	points, ok := read_polygon_points(L, pts, 0, 0)
	defer delete(points)
	testing.expect(t, !ok, "a non-table vertex must poison the polygon")
	testing.expect_value(t, lua_gettop(L), pts)
}

@(test)
test_polygon_valid_points_are_read :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	pts := push_lua(t, L, `return {{0, 0}, {10, 0}, {5, 10}}`)
	points, ok := read_polygon_points(L, pts, 100, 200)
	defer delete(points)
	testing.expect(t, ok)
	testing.expect_value(t, len(points), 3)
	if len(points) == 3 {
		testing.expect_value(t, points[1].x, f32(110))
		testing.expect_value(t, points[2].y, f32(210))
	}
	testing.expect_value(t, lua_gettop(L), pts)
}
