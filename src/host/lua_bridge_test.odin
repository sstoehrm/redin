package main

import "core:fmt"
import "core:testing"
import lua "vendor:lua/5.4"

@(private)
_test_setup :: proc() -> ^lua.State {
	L := lua_init()
	assert(L != nil, "Failed to init Lua VM")
	err := fennel_load(L)
	assert(err == nil, "Failed to load Fennel")
	return L
}

@(test)
test_lua_dostring :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	val, err := lua_dostring(L, `return 42`)
	testing.expect(t, err == nil, "expected no error")
	n, ok := val.(i64)
	testing.expect(t, ok, "expected i64")
	testing.expect_value(t, n, i64(42))
}

@(test)
test_lua_dostring_error :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	_, err := lua_dostring(L, `error("boom")`)
	testing.expect(t, err != nil, "expected an error")
	e := err.?
	testing.expect(t, e.message == "boom", fmt.tprintf("expected 'boom', got '%s'", e.message))
}

@(test)
test_read_table :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	val, err := lua_dostring(L, `return {name = "redin", version = 1}`)
	testing.expect(t, err == nil, "expected no error")
	tbl, ok := val.(Lua_Table)
	testing.expect(t, ok, "expected Lua_Table")

	name, has_name := tbl.entries["name"]
	testing.expect(t, has_name, "expected 'name' key")
	name_str, name_ok := name.(string)
	testing.expect(t, name_ok && name_str == "redin", "expected name == 'redin'")

	ver, has_ver := tbl.entries["version"]
	testing.expect(t, has_ver, "expected 'version' key")
	ver_num, ver_ok := ver.(i64)
	testing.expect(t, ver_ok && ver_num == 1, "expected version == 1")
}

@(test)
test_read_array :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	val, err := lua_dostring(L, `return {10, 20, 30}`)
	testing.expect(t, err == nil, "expected no error")
	arr, ok := val.(Lua_Array)
	testing.expect(t, ok, "expected Lua_Array")
	testing.expect_value(t, len(arr.items), 3)

	v1, v1_ok := arr.items[0].(i64)
	testing.expect(t, v1_ok && v1 == 10, "expected arr[1] == 10")
}

@(test)
test_push_and_roundtrip :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	// Push a table into a global, then read it back via Lua.
	tbl := Lua_Table{entries = make(map[string]Lua_Value)}
	tbl.entries["x"] = i64(100)
	tbl.entries["y"] = f64(3.14)
	tbl.entries["label"] = string("hello")
	tbl.entries["active"] = true

	push_value(L, tbl)
	lua.setglobal(L, "test_data")

	val, err := lua_dostring(L, `return test_data.x`)
	testing.expect(t, err == nil, "expected no error")
	x, ok := val.(i64)
	testing.expect(t, ok && x == 100, "expected x == 100")

	val2, err2 := lua_dostring(L, `return test_data.label`)
	testing.expect(t, err2 == nil, "expected no error")
	lbl, ok2 := val2.(string)
	testing.expect(t, ok2 && lbl == "hello", "expected label == 'hello'")
}

@(test)
test_fennel_eval_returns_table :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	val, err := fennel_eval(L, `{:type :box :width 200 :height 100}`)
	testing.expect(t, err == nil, "expected no error from fennel eval")
	tbl, ok := val.(Lua_Table)
	testing.expect(t, ok, "expected Lua_Table from fennel")

	typ, has_type := tbl.entries["type"]
	testing.expect(t, has_type, "expected 'type' key")
	typ_str, typ_ok := typ.(string)
	testing.expect(t, typ_ok && typ_str == "box", "expected type == 'box'")
}

@(test)
test_fennel_compile_error :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	_, err := fennel_eval(L, `(this-is-not-defined)`)
	testing.expect(t, err != nil, "expected a compile/runtime error")
	e := err.?
	testing.expect(t, len(e.message) > 0, "expected non-empty error message")
}

@(test)
test_fennel_compile_string :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	lua_src, err := fennel_compile(L, `(+ 1 2)`)
	testing.expect(t, err == nil, "expected no error")
	testing.expect(t, len(lua_src) > 0, "expected non-empty Lua output")
}

@(test)
test_lua_call_global :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	// Define a function in Lua, then call it from Odin.
	lua_dostring(L, `function add(a, b) return a + b end`)

	val, err := lua_call_global(L, "add", i64(3), i64(7))
	testing.expect(t, err == nil, "expected no error")
	n, ok := val.(i64)
	testing.expect(t, ok && n == 10, "expected 3 + 7 == 10")
}

@(test)
test_error_parsing :: proc(t: ^testing.T) {
	src, line, msg := _parse_lua_error("test.fnl:42: unknown variable x")
	testing.expect_value(t, src, "test.fnl")
	testing.expect_value(t, line, 42)
	testing.expect_value(t, msg, "unknown variable x")
}

@(test)
test_push_array :: proc(t: ^testing.T) {
	L := _test_setup()
	defer lua_destroy(L)

	arr := Lua_Array{items = make([dynamic]Lua_Value, 0, 3)}
	append(&arr.items, Lua_Value(i64(10)))
	append(&arr.items, Lua_Value(i64(20)))
	append(&arr.items, Lua_Value(i64(30)))

	push_value(L, arr)
	lua.setglobal(L, "test_arr")

	val, err := lua_dostring(L, `return #test_arr`)
	testing.expect(t, err == nil, "expected no error")
	n, ok := val.(i64)
	testing.expect(t, ok && n == 3, "expected array length 3")

	val2, err2 := lua_dostring(L, `return test_arr[2]`)
	testing.expect(t, err2 == nil, "expected no error")
	v, ok2 := val2.(i64)
	testing.expect(t, ok2 && v == 20, "expected test_arr[2] == 20")
}
