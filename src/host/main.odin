package main

import "vendor:raylib"
import "core:fmt"

main :: proc() {
	// Initialize Lua VM
	L := lua_init()
	if L == nil {
		fmt.eprintln("Failed to initialize Lua VM")
		return
	}
	defer lua_destroy(L)

	// Load Fennel compiler
	if err, has_err := fennel_load(L).?; has_err {
		fmt.eprintfln("Failed to load Fennel: %s", lua_error_format(err))
		return
	}

	// Self-test
	fennel_test(L)

	// Initialize Raylib window
	raylib.InitWindow(800, 600, "redin")
	defer raylib.CloseWindow()

	raylib.SetTargetFPS(60)

	for !raylib.WindowShouldClose() {
		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.RAYWHITE)
		raylib.DrawText("redin", 340, 280, 30, raylib.DARKGRAY)
		raylib.EndDrawing()
	}
}
