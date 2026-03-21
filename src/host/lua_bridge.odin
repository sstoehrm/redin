package main

import lua "vendor:lua/5.4"
import "core:fmt"
import "core:os"
import "core:strings"
import fp "core:path/filepath"

// Initialize a new Lua state with standard libraries.
lua_init :: proc() -> ^lua.State {
	L := lua.L_newstate()
	if L == nil {
		return nil
	}
	lua.L_openlibs(L)
	fmt.println("[lua] VM initialized")
	return L
}

// Close the Lua state.
lua_destroy :: proc(L: ^lua.State) {
	lua.close(L)
	fmt.println("[lua] VM destroyed")
}

// Resolve the project root by checking candidate paths for vendor/fennel/fennel.lua.
// Tries: cwd, then directory of argv[0] and one level up from there.
_find_project_root :: proc() -> string {
	check :: proc(dir: string) -> bool {
		candidate := strings.concatenate({dir, "/vendor/fennel/fennel.lua"}, context.temp_allocator)
		return os.exists(candidate)
	}

	// Try current working directory first (covers `make run` from project root)
	if check(".") {
		return "."
	}

	// Try relative to the executable (covers running from build/)
	if len(os.args) > 0 {
		exe_dir := fp.dir(string(os.args[0]), context.temp_allocator)
		if check(exe_dir) {
			return strings.clone(exe_dir)
		}
		parent := fp.dir(exe_dir, context.temp_allocator)
		if check(parent) {
			return strings.clone(parent)
		}
	}

	return "."
}

// Load the Fennel compiler into the Lua VM.
fennel_load :: proc(L: ^lua.State, project_root: string) -> bool {
	fennel_path := strings.concatenate({project_root, "/vendor/fennel/fennel.lua"})
	fennel_cpath := strings.clone_to_cstring(fennel_path)
	result := lua.L_dofile(L, fennel_cpath)
	if result != 0 {
		err := lua.tostring(L, -1)
		fmt.eprintfln("[fennel] failed to load compiler: %s", err)
		lua.pop(L, 1)
		return false
	}

	// The dofile leaves the fennel module table on the stack.
	// Set it as a global so scripts can require it.
	lua.setglobal(L, "fennel")

	fmt.println("[fennel] compiler loaded")
	return true
}

// Compile and execute a Fennel string.
fennel_eval :: proc(L: ^lua.State, code: cstring) -> bool {
	// Use fennel.eval(code)
	lua.getglobal(L, "fennel")
	lua.getfield(L, -1, "eval")
	lua.pushstring(L, code)
	result := lua.pcall(L, 1, 1, 0)
	if result != 0 {
		err := lua.tostring(L, -1)
		fmt.eprintfln("[fennel] eval error: %s", err)
		lua.pop(L, 2) // error + fennel table
		return false
	}

	// Print result if it's a string
	if lua.type(L, -1) == .STRING {
		s := lua.tostring(L, -1)
		fmt.printfln("[fennel] => %s", s)
	}

	lua.pop(L, 2) // result + fennel table
	return true
}

// Quick test that Fennel works.
fennel_test :: proc(L: ^lua.State) {
	fmt.println("[fennel] running self-test...")
	fennel_eval(L, `(print "hello from fennel")`)
}
