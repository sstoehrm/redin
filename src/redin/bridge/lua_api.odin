package bridge

foreign import luajit "luajit:lib/libluajit-5.1.a"

Lua_State :: distinct rawptr
Lua_CFunction :: #type proc "c" (L: ^Lua_State) -> i32

LUA_GLOBALSINDEX  :: -10002
LUA_REGISTRYINDEX :: -10000
LUA_MULTRET       :: -1
LUA_TNIL          :: 0
LUA_TBOOLEAN      :: 1
LUA_TLIGHTUSERDATA :: 2
LUA_TNUMBER       :: 3
LUA_TSTRING       :: 4
LUA_TTABLE        :: 5
LUA_TFUNCTION     :: 6

@(default_calling_convention = "c")
foreign luajit {
	luaL_newstate  :: proc() -> ^Lua_State ---
	luaL_openlibs  :: proc(L: ^Lua_State) ---
	lua_close      :: proc(L: ^Lua_State) ---

	luaL_loadfile   :: proc(L: ^Lua_State, filename: cstring) -> i32 ---
	luaL_loadstring :: proc(L: ^Lua_State, s: cstring) -> i32 ---
	lua_pcall       :: proc(L: ^Lua_State, nargs: i32, nresults: i32, errfunc: i32) -> i32 ---

	lua_gettop    :: proc(L: ^Lua_State) -> i32 ---
	lua_settop    :: proc(L: ^Lua_State, index: i32) ---
	lua_pushvalue :: proc(L: ^Lua_State, index: i32) ---
	lua_remove    :: proc(L: ^Lua_State, index: i32) ---
	lua_type      :: proc(L: ^Lua_State, index: i32) -> i32 ---
	lua_typename  :: proc(L: ^Lua_State, tp: i32) -> cstring ---

	lua_pushnil       :: proc(L: ^Lua_State) ---
	lua_pushnumber    :: proc(L: ^Lua_State, n: f64) ---
	lua_pushinteger   :: proc(L: ^Lua_State, n: i64) ---
	lua_pushlstring   :: proc(L: ^Lua_State, s: cstring, len: uint) ---
	lua_pushstring    :: proc(L: ^Lua_State, s: cstring) ---
	lua_pushboolean   :: proc(L: ^Lua_State, b: i32) ---
	lua_pushcclosure  :: proc(L: ^Lua_State, f: Lua_CFunction, n: i32) ---

	lua_tonumber  :: proc(L: ^Lua_State, index: i32) -> f64 ---
	lua_tointeger :: proc(L: ^Lua_State, index: i32) -> i64 ---
	lua_toboolean :: proc(L: ^Lua_State, index: i32) -> i32 ---
	lua_tolstring :: proc(L: ^Lua_State, index: i32, len: ^uint) -> cstring ---
	lua_topointer :: proc(L: ^Lua_State, index: i32) -> rawptr ---

	lua_createtable :: proc(L: ^Lua_State, narr: i32, nrec: i32) ---
	lua_settable    :: proc(L: ^Lua_State, index: i32) ---
	lua_gettable    :: proc(L: ^Lua_State, index: i32) ---
	lua_setfield    :: proc(L: ^Lua_State, index: i32, k: cstring) ---
	lua_getfield    :: proc(L: ^Lua_State, index: i32, k: cstring) ---
	lua_rawget      :: proc(L: ^Lua_State, index: i32) ---
	lua_rawgeti     :: proc(L: ^Lua_State, index: i32, n: i32) ---
	lua_rawseti     :: proc(L: ^Lua_State, index: i32, n: i32) ---
	lua_next        :: proc(L: ^Lua_State, index: i32) -> i32 ---
	lua_objlen      :: proc(L: ^Lua_State, index: i32) -> uint ---

	luaL_ref   :: proc(L: ^Lua_State, t: i32) -> i32 ---
	luaL_unref :: proc(L: ^Lua_State, t: i32, ref: i32) ---

	luaL_error :: proc(L: ^Lua_State, fmt: cstring, #c_vararg args: ..any) -> i32 ---
}

lua_pop :: #force_inline proc "contextless" (L: ^Lua_State, n: i32) {
	lua_settop(L, -(n) - 1)
}

lua_newtable :: #force_inline proc "contextless" (L: ^Lua_State) {
	lua_createtable(L, 0, 0)
}

lua_pushcfunction :: #force_inline proc "contextless" (L: ^Lua_State, f: Lua_CFunction) {
	lua_pushcclosure(L, f, 0)
}

lua_tostring_raw :: #force_inline proc "contextless" (L: ^Lua_State, index: i32) -> cstring {
	return lua_tolstring(L, index, nil)
}

lua_getglobal :: #force_inline proc "contextless" (L: ^Lua_State, name: cstring) {
	lua_getfield(L, LUA_GLOBALSINDEX, name)
}

lua_setglobal :: #force_inline proc "contextless" (L: ^Lua_State, name: cstring) {
	lua_setfield(L, LUA_GLOBALSINDEX, name)
}

lua_isnil :: #force_inline proc "contextless" (L: ^Lua_State, index: i32) -> bool {
	return lua_type(L, index) == LUA_TNIL
}

lua_istable :: #force_inline proc "contextless" (L: ^Lua_State, index: i32) -> bool {
	return lua_type(L, index) == LUA_TTABLE
}

lua_isstring :: #force_inline proc "contextless" (L: ^Lua_State, index: i32) -> bool {
	return lua_type(L, index) == LUA_TSTRING
}

lua_isnumber :: #force_inline proc "contextless" (L: ^Lua_State, index: i32) -> bool {
	return lua_type(L, index) == LUA_TNUMBER
}

luaL_dofile :: proc(L: ^Lua_State, filename: cstring) -> i32 {
	result := luaL_loadfile(L, filename)
	if result != 0 {return result}
	return lua_pcall(L, 0, LUA_MULTRET, 0)
}

luaL_dostring :: proc(L: ^Lua_State, s: cstring) -> i32 {
	result := luaL_loadstring(L, s)
	if result != 0 {return result}
	return lua_pcall(L, 0, LUA_MULTRET, 0)
}
