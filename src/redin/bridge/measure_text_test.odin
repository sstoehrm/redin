package bridge

import "core:testing"

// #263 L2: redin_measure_text skipped the lua_isstring guard that every
// sibling host cfunc applies before dereferencing an argument, so a nil
// (or table, or missing) text argument reached rl.MeasureTextEx as a NULL
// cstring — strlen(NULL) → SIGSEGV. Reachable from app code with a plain
// `(redin.measure_text nil 12)`, e.g. an accidental miss on a state field.
// The guard returns before any font machinery is touched, so this test
// runs headless.

@(test)
test_measure_text_nil_arg_no_crash :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// Host cfuncs enter through `context = g_context`, which bridge_init
	// normally seeds; do the same here.
	g_context = context

	lua_pushnil(L)
	lua_pushnumber(L, 12)
	testing.expect_value(t, redin_measure_text(L), 0)
}

@(test)
test_measure_text_table_arg_no_crash :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	g_context = context

	lua_newtable(L)
	lua_pushnumber(L, 12)
	testing.expect_value(t, redin_measure_text(L), 0)
}
