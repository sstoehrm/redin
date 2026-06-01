package bridge

import "core:fmt"
import "core:strings"

// #162 L2: the app path is forwarded to fennel.dofile / luaL_dofile as a
// C string. An embedded NUL truncates there, so the loader would silently
// act on a prefix of the supplied path. Reject empty or NUL-containing
// paths up front. The user controls the CLI argument, so this is a
// robustness guard (clean refusal over confusing downstream errors), not
// an exploit barrier — hence absolute paths and any extension stay valid.
valid_app_path :: proc(path: string) -> bool {
	if len(path) == 0 do return false
	if strings.contains_rune(path, 0) do return false
	return true
}

load_app :: proc(b: ^Bridge, app_file: string) -> bool {
	if !valid_app_path(app_file) {
		fmt.eprintfln("Invalid app file path (empty or contains NUL)")
		return false
	}

	is_fennel := strings.has_suffix(app_file, ".fnl")
	cs := strings.clone_to_cstring(app_file)
	defer delete(cs)

	if is_fennel {
		lua_getglobal(b.L, "require")
		lua_pushstring(b.L, "fennel")
		if lua_pcall(b.L, 1, 1, 0) != 0 {
			msg := lua_tostring_raw(b.L, -1)
			fmt.eprintfln("Error loading fennel: %s", msg)
			lua_pop(b.L, 1)
			return false
		}
		lua_getfield(b.L, -1, "dofile")
		lua_remove(b.L, -2)
		lua_pushstring(b.L, cs)
		if lua_pcall(b.L, 1, 0, 0) != 0 {
			msg := lua_tostring_raw(b.L, -1)
			fmt.eprintfln("Error loading app: %s", msg)
			lua_pop(b.L, 1)
			return false
		}
	} else {
		if luaL_dofile(b.L, cs) != 0 {
			msg := lua_tostring_raw(b.L, -1)
			fmt.eprintfln("Error loading app: %s", msg)
			lua_pop(b.L, 1)
			return false
		}
	}

	return true
}
