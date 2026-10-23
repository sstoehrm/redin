package bridge

// #217 L6: /state/<path> caps the number of dot-separated segments (32) but
// never bounded the length of any single segment. It is safe in practice today
// — the request path is already bounded by the header buffer — but the cap is
// cheap defence-in-depth. any_segment_too_long is the pure predicate behind it.

import "core:strings"
import "core:testing"

@(test)
test_any_segment_too_long_flags_overlong :: proc(t: ^testing.T) {
	long := strings.repeat("a", MAX_PATH_SEGMENT_LEN + 1, context.temp_allocator)
	segments := []string{"form", long, "name"}
	testing.expect(t, any_segment_too_long(segments),
		"a segment past MAX_PATH_SEGMENT_LEN must be flagged")
}

@(test)
test_any_segment_too_long_allows_normal :: proc(t: ^testing.T) {
	at_cap := strings.repeat("b", MAX_PATH_SEGMENT_LEN, context.temp_allocator)
	segments := []string{"form", "name", at_cap}
	testing.expect(t, !any_segment_too_long(segments),
		"segments at or under the cap must pass")
}

// Review C15: /state/<dot.path> pushed every segment as a string key, so
// array elements were unreachable even though docs/core-api.md documents
// `/state/items.0.text`. Integer segments that miss as a string key are now
// retried as a 0-based index into the Lua sequence (matching /state's JSON
// array output).
@(private = "file")
walk_json :: proc(L: ^Lua_State, path: string) -> string {
	segments := strings.split(path, ".")
	defer delete(segments)
	lua_getglobal(L, "S")
	walk_state_path(L, segments)
	b := strings.builder_make(context.temp_allocator)
	lua_value_to_json(&b, L, -1)
	lua_pop(L, 1)
	return strings.to_string(b)
}

@(test)
test_walk_state_path_array_index :: proc(t: ^testing.T) {
	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	src: cstring = `S = {items = {{text = "a"}, {text = "b"}},
	                    zero = {["0"] = "by-string", "by-index"},
	                    name = "n"}`
	testing.expect_value(t, luaL_dostring(L, src), 0)

	testing.expect_value(t, walk_json(L, "items.0.text"), `"a"`)
	testing.expect_value(t, walk_json(L, "items.1.text"), `"b"`)
	testing.expect_value(t, walk_json(L, "items.2.text"), `null`)
	testing.expect_value(t, walk_json(L, "items.1"), `{"text":"b"}`)
	// A string key wins over the index fallback.
	testing.expect_value(t, walk_json(L, "zero.0"), `"by-string"`)
	// Plain string keys are unchanged; non-digit segments never index.
	testing.expect_value(t, walk_json(L, "name"), `"n"`)
	testing.expect_value(t, walk_json(L, "items.-1"), `null`)
	testing.expect_value(t, walk_json(L, "items.x"), `null`)
	// Walking through a non-table yields null.
	testing.expect_value(t, walk_json(L, "name.0"), `null`)
	// Oversized index segments don't overflow; they just miss.
	testing.expect_value(t, walk_json(L, "items.99999999999"), `null`)
	testing.expect_value(t, lua_gettop(L), 0)
}

@(test)
test_any_segment_too_long_empty :: proc(t: ^testing.T) {
	testing.expect(t, !any_segment_too_long([]string{}), "no segments => nothing too long")
	testing.expect(t, !any_segment_too_long([]string{""}), "empty segment is not too long")
}
