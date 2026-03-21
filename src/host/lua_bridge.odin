package main

import lua "vendor:lua/5.4"
import "core:fmt"

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

// Load the Fennel compiler into the Lua VM.
fennel_load :: proc(L: ^lua.State) -> bool {
	result := lua.L_dofile(L, "vendor/fennel/fennel.lua")
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
