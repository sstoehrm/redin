package bridge

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "base:runtime"

// ---------------------------------------------------------------------------
// JSON string builder primitives
// ---------------------------------------------------------------------------

json_begin_object :: proc(b: ^strings.Builder) { strings.write_byte(b, '{') }
json_end_object :: proc(b: ^strings.Builder) { strings.write_byte(b, '}') }
json_begin_array :: proc(b: ^strings.Builder) { strings.write_byte(b, '[') }
json_end_array :: proc(b: ^strings.Builder) { strings.write_byte(b, ']') }
json_comma :: proc(b: ^strings.Builder) { strings.write_byte(b, ',') }
json_colon :: proc(b: ^strings.Builder) { strings.write_byte(b, ':') }

json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			strings.write_rune(b, c)
		}
	}
	strings.write_byte(b, '"')
}

json_number :: proc(b: ^strings.Builder, n: f64) {
	buf: [64]u8
	s := strconv.write_float(buf[:], n, 'g', -1, 64)
	for c in s {
		if c != '+' do strings.write_byte(b, u8(c))
	}
}

json_int :: proc(b: ^strings.Builder, n: i64) {
	buf: [32]u8
	s := strconv.write_int(buf[:], n, 10)
	strings.write_string(b, s)
}

json_bool :: proc(b: ^strings.Builder, v: bool) {
	strings.write_string(b, v ? "true" : "false")
}

json_null :: proc(b: ^strings.Builder) {
	strings.write_string(b, "null")
}

json_key :: proc(b: ^strings.Builder, key: string) {
	json_string(b, key)
	json_colon(b)
}

// ---------------------------------------------------------------------------
// Lua value -> JSON
// ---------------------------------------------------------------------------

// Shared depth cap for encoder and decoder. 128 is well clear of any
// legitimate data structure and far below the host's native stack
// limit, so going deeper is either a cycle (encoder) or adversarial
// input (decoder). Both sides bail with `null` / parse-failure rather
// than recurse forever.
MAX_JSON_DEPTH :: 128

@(private = "file")
Json_Encode_Ctx :: struct {
	// Tables currently on the recursion path, by lua_topointer. A
	// "path" set rather than a "seen" set — a DAG where the same
	// sub-table appears under multiple keys should serialize each
	// occurrence in full. Only cycles back into an ancestor are
	// replaced with `null`.
	path:  map[rawptr]bool,
	depth: int,
}

lua_value_to_json :: proc(b: ^strings.Builder, L: ^Lua_State, index: i32) {
	ctx: Json_Encode_Ctx
	defer delete(ctx.path)
	lua_value_to_json_inner(b, L, index, &ctx)
}

@(private = "file")
lua_value_to_json_inner :: proc(b: ^strings.Builder, L: ^Lua_State, index: i32, ctx: ^Json_Encode_Ctx) {
	if ctx.depth >= MAX_JSON_DEPTH {
		json_null(b)
		return
	}
	abs_idx := index < 0 ? lua_gettop(L) + index + 1 : index
	t := lua_type(L, abs_idx)
	switch t {
	case LUA_TNIL:
		json_null(b)
	case LUA_TBOOLEAN:
		json_bool(b, lua_toboolean(L, abs_idx) != 0)
	case LUA_TNUMBER:
		json_number(b, lua_tonumber(L, abs_idx))
	case LUA_TSTRING:
		json_string(b, string(lua_tostring_raw(L, abs_idx)))
	case LUA_TTABLE:
		ptr := lua_topointer(L, abs_idx)
		if ptr in ctx.path {
			// Cycle back to an ancestor — emit null and stop.
			json_null(b)
			return
		}
		ctx.path[ptr] = true
		ctx.depth += 1
		defer {
			delete_key(&ctx.path, ptr)
			ctx.depth -= 1
		}

		lua_rawgeti(L, abs_idx, 1)
		is_array := !lua_isnil(L, -1)
		lua_pop(L, 1)

		if is_array {
			json_begin_array(b)
			n := i32(lua_objlen(L, abs_idx))
			for i: i32 = 1; i <= n; i += 1 {
				if i > 1 do json_comma(b)
				lua_rawgeti(L, abs_idx, i)
				lua_value_to_json_inner(b, L, -1, ctx)
				lua_pop(L, 1)
			}
			json_end_array(b)
		} else {
			json_begin_object(b)
			first := true
			lua_pushnil(L)
			for lua_next(L, abs_idx) != 0 {
				if lua_isstring(L, -2) {
					if !first do json_comma(b)
					first = false
					json_key(b, string(lua_tostring_raw(L, -2)))
					lua_value_to_json_inner(b, L, -1, ctx)
				}
				lua_pop(L, 1)
			}
			json_end_object(b)
		}
	case:
		json_null(b)
	}
}

// ---------------------------------------------------------------------------
// Host functions: redin.json_encode / redin.json_decode
// ---------------------------------------------------------------------------

redin_json_encode :: proc "c" (L: ^Lua_State) -> i32 {
	context = runtime.default_context()
	b := strings.builder_make()
	lua_value_to_json(&b, L, 1)
	s := strings.to_string(b)
	lua_pushlstring(L, cstring(raw_data(s)), uint(len(s)))
	strings.builder_destroy(&b)
	return 1
}

redin_json_decode :: proc "c" (L: ^Lua_State) -> i32 {
	context = runtime.default_context()
	s := string(lua_tostring_raw(L, 1))
	if len(s) == 0 {
		lua_pushnil(L)
		return 1
	}
	pos := 0
	if !json_decode_value(L, s, &pos) {
		luaL_error(L, "invalid JSON")
	}
	return 1
}

// ---------------------------------------------------------------------------
// JSON decoder: string -> Lua values on stack
// ---------------------------------------------------------------------------

@(private = "file")
json_skip_ws :: proc(s: string, pos: ^int) {
	for pos^ < len(s) {
		c := s[pos^]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			pos^ += 1
		} else {
			break
		}
	}
}

json_decode_value :: proc(L: ^Lua_State, s: string, pos: ^int) -> bool {
	return json_decode_value_at(L, s, pos, 0)
}

@(private = "file")
json_decode_value_at :: proc(L: ^Lua_State, s: string, pos: ^int, depth: int) -> bool {
	if depth > MAX_JSON_DEPTH do return false
	json_skip_ws(s, pos)
	if pos^ >= len(s) do return false
	c := s[pos^]
	switch c {
	case '"':
		return json_decode_string(L, s, pos)
	case '{':
		return json_decode_object(L, s, pos, depth)
	case '[':
		return json_decode_array(L, s, pos, depth)
	case 't':
		return json_decode_literal(L, s, pos, "true")
	case 'f':
		return json_decode_literal(L, s, pos, "false")
	case 'n':
		return json_decode_literal(L, s, pos, "null")
	case '-', '0' ..= '9':
		return json_decode_number(L, s, pos)
	}
	return false
}

@(private = "file")
json_decode_string :: proc(L: ^Lua_State, s: string, pos: ^int) -> bool {
	if s[pos^] != '"' do return false
	pos^ += 1
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for pos^ < len(s) {
		c := s[pos^]
		if c == '"' {
			pos^ += 1
			result := strings.to_string(b)
			lua_pushlstring(L, cstring(raw_data(result)), uint(len(result)))
			return true
		}
		if c == '\\' {
			pos^ += 1
			if pos^ >= len(s) do return false
			esc := s[pos^]
			switch esc {
			case '"':
				strings.write_byte(&b, '"')
			case '\\':
				strings.write_byte(&b, '\\')
			case '/':
				strings.write_byte(&b, '/')
			case 'b':
				strings.write_byte(&b, '\b')
			case 'f':
				strings.write_byte(&b, '\f')
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case 't':
				strings.write_byte(&b, '\t')
			case 'u':
				// Need four hex digits at s[pos^+1 .. pos^+5].
				if pos^ + 5 > len(s) do return false
				hex := s[pos^ + 1:pos^ + 5]
				cp, ok := strconv.parse_uint(hex, 16)
				if !ok do return false
				pos^ += 4

				// Surrogate pair handling per RFC 8259 §7. A high
				// surrogate must be followed by `\uYYYY` where YYYY is
				// a low surrogate; together they encode one codepoint
				// outside the BMP. A lone low surrogate is invalid.
				cp32 := u32(cp)
				switch {
				case cp32 >= 0xD800 && cp32 <= 0xDBFF:
					// Need the trailing \uYYYY: 6 chars after current pos^.
					if pos^ + 7 > len(s) do return false
					if s[pos^ + 1] != '\\' || s[pos^ + 2] != 'u' do return false
					lo, ok2 := strconv.parse_uint(s[pos^ + 3:pos^ + 7], 16)
					if !ok2 do return false
					lo32 := u32(lo)
					if lo32 < 0xDC00 || lo32 > 0xDFFF do return false
					cp32 = 0x10000 + ((cp32 - 0xD800) << 10) + (lo32 - 0xDC00)
					pos^ += 6 // consume \uYYYY
				case cp32 >= 0xDC00 && cp32 <= 0xDFFF:
					// Lone low surrogate.
					return false
				}
				buf, n := utf8.encode_rune(rune(cp32))
				strings.write_bytes(&b, buf[:n])
			case:
				return false
			}
			pos^ += 1
		} else {
			strings.write_byte(&b, c)
			pos^ += 1
		}
	}
	return false
}

@(private = "file")
json_decode_number :: proc(L: ^Lua_State, s: string, pos: ^int) -> bool {
	start := pos^
	if pos^ < len(s) && s[pos^] == '-' do pos^ += 1
	for pos^ < len(s) && s[pos^] >= '0' && s[pos^] <= '9' do pos^ += 1
	if pos^ < len(s) && s[pos^] == '.' {
		pos^ += 1
		for pos^ < len(s) && s[pos^] >= '0' && s[pos^] <= '9' do pos^ += 1
	}
	if pos^ < len(s) && (s[pos^] == 'e' || s[pos^] == 'E') {
		pos^ += 1
		if pos^ < len(s) && (s[pos^] == '+' || s[pos^] == '-') do pos^ += 1
		for pos^ < len(s) && s[pos^] >= '0' && s[pos^] <= '9' do pos^ += 1
	}
	num, ok := strconv.parse_f64(s[start:pos^])
	if !ok do return false
	lua_pushnumber(L, num)
	return true
}

@(private = "file")
json_decode_literal :: proc(L: ^Lua_State, s: string, pos: ^int, lit: string) -> bool {
	if pos^ + len(lit) > len(s) do return false
	if s[pos^:pos^ + len(lit)] != lit do return false
	pos^ += len(lit)
	switch lit {
	case "true":
		lua_pushboolean(L, 1)
	case "false":
		lua_pushboolean(L, 0)
	case "null":
		lua_pushnil(L)
	}
	return true
}

@(private = "file")
json_decode_object :: proc(L: ^Lua_State, s: string, pos: ^int, depth: int) -> bool {
	if s[pos^] != '{' do return false
	pos^ += 1
	lua_newtable(L)
	json_skip_ws(s, pos)
	if pos^ < len(s) && s[pos^] == '}' {
		pos^ += 1
		return true
	}
	for {
		json_skip_ws(s, pos)
		if pos^ >= len(s) || s[pos^] != '"' {lua_pop(L, 1);return false}
		if !json_decode_string(L, s, pos) {lua_pop(L, 1);return false}
		json_skip_ws(s, pos)
		if pos^ >= len(s) || s[pos^] != ':' {lua_pop(L, 2);return false}
		pos^ += 1
		if !json_decode_value_at(L, s, pos, depth + 1) {lua_pop(L, 2);return false}
		lua_settable(L, -3)
		json_skip_ws(s, pos)
		if pos^ >= len(s) {lua_pop(L, 1);return false}
		if s[pos^] == '}' {
			pos^ += 1
			return true
		}
		if s[pos^] != ',' {lua_pop(L, 1);return false}
		pos^ += 1
	}
}

@(private = "file")
json_decode_array :: proc(L: ^Lua_State, s: string, pos: ^int, depth: int) -> bool {
	if s[pos^] != '[' do return false
	pos^ += 1
	lua_newtable(L)
	json_skip_ws(s, pos)
	if pos^ < len(s) && s[pos^] == ']' {
		pos^ += 1
		return true
	}
	idx: i32 = 1
	for {
		if !json_decode_value_at(L, s, pos, depth + 1) {lua_pop(L, 1);return false}
		lua_rawseti(L, -2, idx)
		idx += 1
		json_skip_ws(s, pos)
		if pos^ >= len(s) {lua_pop(L, 1);return false}
		if s[pos^] == ']' {
			pos^ += 1
			return true
		}
		if s[pos^] != ',' {lua_pop(L, 1);return false}
		pos^ += 1
	}
}
