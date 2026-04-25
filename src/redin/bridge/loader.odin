package bridge

import "core:fmt"
import "core:strings"

load_app :: proc(b: ^Bridge, app_file: string) -> bool {
	if len(app_file) == 0 {
		fmt.eprintfln("No app file specified")
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
