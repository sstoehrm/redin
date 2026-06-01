package bridge

// #162 L2: load_app forwards os.args[1] straight to fennel.dofile /
// luaL_dofile. A path with an embedded NUL truncates at the C-string
// boundary, so the bytes after the NUL silently vanish and the loader
// acts on a different path than the one supplied — confusing at best.
// valid_app_path is the pure guard load_app consults before handing the
// path to Lua.

import "core:testing"

@(test)
test_valid_app_path_accepts_normal :: proc(t: ^testing.T) {
	testing.expect(t, valid_app_path("main.fnl"), "ordinary .fnl path")
	testing.expect(t, valid_app_path("examples/kitchen-sink.fnl"), "nested path")
	testing.expect(t, valid_app_path("app.lua"), "lua path")
	testing.expect(t, valid_app_path("/abs/path/main.fnl"), "absolute is fine — user controls the CLI")
}

@(test)
test_valid_app_path_rejects_empty :: proc(t: ^testing.T) {
	testing.expect(t, !valid_app_path(""), "empty path rejected")
}

@(test)
test_valid_app_path_rejects_nul :: proc(t: ^testing.T) {
	testing.expect(t, !valid_app_path("main.fnl\x00.lua"), "embedded NUL rejected")
	testing.expect(t, !valid_app_path("\x00"), "lone NUL rejected")
}
