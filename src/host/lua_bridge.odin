package main

import lua "vendor:lua/5.4"
import "core:fmt"
import "core:strings"
import c "core:c/libc"

// ---------------------------------------------------------------------------
// Lua_Value: Odin-side tagged union mirroring Lua types
// ---------------------------------------------------------------------------

Lua_Value :: union {
	Lua_Nil,
	bool,
	f64,
	i64,
	string,
	Lua_Table,
	Lua_Array,
}

Lua_Nil :: struct {}

// A table with string keys.
Lua_Table :: struct {
	entries: map[string]Lua_Value,
}

// A table with sequential integer keys (1-based in Lua).
Lua_Array :: struct {
	items: [dynamic]Lua_Value,
}

// ---------------------------------------------------------------------------
// Lua_Error: structured error from Lua/Fennel
// ---------------------------------------------------------------------------

Lua_Error :: struct {
	message: string,
	source:  string, // filename or chunk name
	line:    int,
}

lua_error_format :: proc(err: Lua_Error) -> string {
	if err.source != "" && err.line > 0 {
		return fmt.aprintf("%s:%d: %s", err.source, err.line, err.message)
	}
	return strings.clone(err.message)
}

// ---------------------------------------------------------------------------
// VM lifecycle
// ---------------------------------------------------------------------------

lua_init :: proc() -> ^lua.State {
	L := lua.L_newstate()
	if L == nil {
		return nil
	}
	lua.L_openlibs(L)
	fmt.println("[lua] VM initialized")
	return L
}

lua_destroy :: proc(L: ^lua.State) {
	lua.close(L)
	fmt.println("[lua] VM destroyed")
}

// ---------------------------------------------------------------------------
// Execute Lua code
// ---------------------------------------------------------------------------

// Execute a Lua string. Returns an error if it fails.
lua_dostring :: proc(L: ^lua.State, code: cstring, chunk_name: cstring = "string") -> (Lua_Value, Maybe(Lua_Error)) {
	if lua.L_loadbuffer(L, transmute([^]byte)code, c.strlen(code), chunk_name) != .OK {
		err := _pop_error(L)
		return Lua_Nil{}, err
	}
	if lua.pcall(L, 0, 1, 0) != 0 {
		err := _pop_error(L)
		return Lua_Nil{}, err
	}
	val := read_value(L, -1)
	lua.pop(L, 1)
	return val, nil
}

// Execute a Lua file. Returns an error if it fails.
lua_dofile :: proc(L: ^lua.State, path: cstring) -> (Lua_Value, Maybe(Lua_Error)) {
	if lua.L_loadfile(L, path) != .OK {
		err := _pop_error(L)
		return Lua_Nil{}, err
	}
	if lua.pcall(L, 0, 1, 0) != 0 {
		err := _pop_error(L)
		return Lua_Nil{}, err
	}
	val := read_value(L, -1)
	lua.pop(L, 1)
	return val, nil
}

// ---------------------------------------------------------------------------
// Fennel integration
// ---------------------------------------------------------------------------

// Load the Fennel compiler into the VM.
fennel_load :: proc(L: ^lua.State) -> Maybe(Lua_Error) {
	result := lua.L_dofile(L, "vendor/fennel/fennel.lua")
	if result != 0 {
		return _pop_error(L)
	}
	// dofile leaves the fennel module table on the stack — set as global.
	lua.setglobal(L, "fennel")
	fmt.println("[fennel] compiler loaded")
	return nil
}

// Compile a Fennel string to Lua source. Does not execute it.
fennel_compile :: proc(L: ^lua.State, code: cstring, filename: cstring = "fennel") -> (string, Maybe(Lua_Error)) {
	top := lua.gettop(L)
	defer lua.settop(L, top)

	lua.getglobal(L, "fennel")
	lua.getfield(L, -1, "compileString")
	lua.pushstring(L, code)

	// Options table: {filename = filename}
	lua.newtable(L)
	lua.pushstring(L, filename)
	lua.setfield(L, -2, "filename")

	if lua.pcall(L, 2, 1, 0) != 0 {
		err := _pop_error(L)
		return "", err
	}

	result := lua.tostring(L, -1)
	return strings.clone(string(result)), nil
}

// Compile and execute a Fennel string. Returns the result.
fennel_eval :: proc(L: ^lua.State, code: cstring, filename: cstring = "fennel") -> (Lua_Value, Maybe(Lua_Error)) {
	top := lua.gettop(L)

	lua.getglobal(L, "fennel")
	lua.getfield(L, -1, "eval")
	lua.pushstring(L, code)

	// Options table: {filename = filename}
	lua.newtable(L)
	lua.pushstring(L, filename)
	lua.setfield(L, -2, "filename")

	if lua.pcall(L, 2, 1, 0) != 0 {
		err := _pop_error(L)
		lua.settop(L, top)
		return Lua_Nil{}, err
	}

	val := read_value(L, -1)
	lua.settop(L, top)
	return val, nil
}

// Compile and execute a Fennel file. Returns the result.
fennel_dofile :: proc(L: ^lua.State, path: cstring) -> (Lua_Value, Maybe(Lua_Error)) {
	top := lua.gettop(L)

	lua.getglobal(L, "fennel")
	lua.getfield(L, -1, "dofile")
	lua.pushstring(L, path)

	if lua.pcall(L, 1, 1, 0) != 0 {
		err := _pop_error(L)
		lua.settop(L, top)
		return Lua_Nil{}, err
	}

	val := read_value(L, -1)
	lua.settop(L, top)
	return val, nil
}

// ---------------------------------------------------------------------------
// Call a Lua/Fennel function by global name
// ---------------------------------------------------------------------------

// Call a global Lua function with arguments, returning a single result.
lua_call_global :: proc(L: ^lua.State, name: cstring, args: ..Lua_Value) -> (Lua_Value, Maybe(Lua_Error)) {
	top := lua.gettop(L)

	lua.getglobal(L, name)
	if lua.type(L, -1) != .FUNCTION {
		lua.settop(L, top)
		return Lua_Nil{}, Lua_Error{message = fmt.aprintf("'%s' is not a function", name)}
	}

	for arg in args {
		push_value(L, arg)
	}

	if lua.pcall(L, c.int(len(args)), 1, 0) != 0 {
		err := _pop_error(L)
		lua.settop(L, top)
		return Lua_Nil{}, err
	}

	val := read_value(L, -1)
	lua.settop(L, top)
	return val, nil
}

// ---------------------------------------------------------------------------
// Read Lua stack values → Lua_Value
// ---------------------------------------------------------------------------

// Read the Lua value at the given stack index into a Lua_Value.
read_value :: proc(L: ^lua.State, idx: c.int) -> Lua_Value {
	#partial switch lua.type(L, idx) {
	case .NIL, .NONE:
		return Lua_Nil{}
	case .BOOLEAN:
		return bool(lua.toboolean(L, idx))
	case .NUMBER:
		if lua.isinteger(L, idx) {
			return i64(lua.tointeger(L, idx))
		}
		return f64(lua.tonumber(L, idx))
	case .STRING:
		s := lua.tostring(L, idx)
		return strings.clone(string(s))
	case .TABLE:
		return _read_table(L, idx)
	case:
		// Functions, userdata, threads — not representable, return nil.
		return Lua_Nil{}
	}
}

// Read a Lua table. Detects whether it's an array (sequential 1..n keys) or a map.
@(private)
_read_table :: proc(L: ^lua.State, idx: c.int) -> Lua_Value {
	abs_idx := lua.absindex(L, idx)

	// Check if it's an array: has rawlen > 0 and key 1 exists.
	arr_len := int(lua.rawlen(L, abs_idx))

	if arr_len > 0 {
		// Verify it's really an array by checking key 1 exists.
		lua.rawgeti(L, abs_idx, 1)
		is_array := lua.type(L, -1) != .NIL
		lua.pop(L, 1)

		if is_array {
			items := make([dynamic]Lua_Value, 0, arr_len)
			for i := 1; i <= arr_len; i += 1 {
				lua.rawgeti(L, abs_idx, lua.Integer(i))
				append(&items, read_value(L, -1))
				lua.pop(L, 1)
			}
			return Lua_Array{items = items}
		}
	}

	// It's a map table.
	entries := make(map[string]Lua_Value)
	lua.pushnil(L)
	for lua.next(L, abs_idx) != 0 {
		// Key is at -2, value at -1.
		// Only support string keys for now.
		if lua.type(L, -2) == .STRING {
			key := string(lua.tostring(L, -2))
			val := read_value(L, -1)
			entries[strings.clone(key)] = val
		}
		lua.pop(L, 1) // pop value, keep key for next iteration
	}
	return Lua_Table{entries = entries}
}

// ---------------------------------------------------------------------------
// Push Lua_Value → Lua stack
// ---------------------------------------------------------------------------

// Push an Odin Lua_Value onto the Lua stack.
push_value :: proc(L: ^lua.State, val: Lua_Value) {
	switch v in val {
	case Lua_Nil:
		lua.pushnil(L)
	case bool:
		lua.pushboolean(L, b32(v))
	case f64:
		lua.pushnumber(L, lua.Number(v))
	case i64:
		lua.pushinteger(L, lua.Integer(v))
	case string:
		lua.pushstring(L, strings.clone_to_cstring(v))
	case Lua_Table:
		_push_table(L, v)
	case Lua_Array:
		_push_array(L, v)
	}
}

@(private)
_push_table :: proc(L: ^lua.State, tbl: Lua_Table) {
	lua.createtable(L, 0, c.int(len(tbl.entries)))
	for key, val in tbl.entries {
		lua.pushstring(L, strings.clone_to_cstring(key))
		push_value(L, val)
		lua.settable(L, -3)
	}
}

@(private)
_push_array :: proc(L: ^lua.State, arr: Lua_Array) {
	lua.createtable(L, c.int(len(arr.items)), 0)
	for val, i in arr.items {
		push_value(L, val)
		lua.seti(L, -2, lua.Integer(i + 1)) // Lua arrays are 1-based
	}
}

// ---------------------------------------------------------------------------
// Error handling helpers
// ---------------------------------------------------------------------------

// Pop the error message from the Lua stack and parse into a Lua_Error.
@(private)
_pop_error :: proc(L: ^lua.State) -> Lua_Error {
	msg_cstr := lua.tostring(L, -1)
	lua.pop(L, 1)

	if msg_cstr == nil {
		return Lua_Error{message = "unknown Lua error"}
	}

	msg := string(msg_cstr)

	// Try to parse "source:line: message" format.
	source, line, message := _parse_lua_error(msg)
	return Lua_Error{
		message = strings.clone(message),
		source  = strings.clone(source),
		line    = line,
	}
}

// Parse a Lua error string like "filename:42: some error" into components.
@(private)
_parse_lua_error :: proc(msg: string) -> (source: string, line: int, message: string) {
	// Find first colon (source delimiter).
	first_colon := -1
	for i := 0; i < len(msg); i += 1 {
		if msg[i] == ':' {
			first_colon = i
			break
		}
	}
	if first_colon < 0 {
		return "", 0, msg
	}

	// Find second colon (line number delimiter).
	second_colon := -1
	for i := first_colon + 1; i < len(msg); i += 1 {
		if msg[i] == ':' {
			second_colon = i
			break
		}
	}
	if second_colon < 0 {
		return "", 0, msg
	}

	// Parse line number between first and second colon.
	line_str := msg[first_colon + 1:second_colon]
	line_num := 0
	for ch in line_str {
		if ch >= '0' && ch <= '9' {
			line_num = line_num * 10 + int(ch - '0')
		} else {
			// Not a number — can't parse, return raw message.
			return "", 0, msg
		}
	}

	src := msg[:first_colon]
	// Skip the ": " after the second colon.
	rest_start := second_colon + 1
	if rest_start < len(msg) && msg[rest_start] == ' ' {
		rest_start += 1
	}
	return src, line_num, msg[rest_start:]
}

// ---------------------------------------------------------------------------
// Self-test (called from main during init)
// ---------------------------------------------------------------------------

fennel_test :: proc(L: ^lua.State) {
	fmt.println("[fennel] running self-test...")
	_, err := fennel_eval(L, `(print "hello from fennel")`)
	if err != nil {
		e := err.?
		fmt.eprintfln("[fennel] self-test failed: %s", lua_error_format(e))
	}
}
