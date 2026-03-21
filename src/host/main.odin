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

	// Find project root and load Fennel compiler
	project_root := _find_project_root()
	if !fennel_load(L, project_root) {
		fmt.eprintln("Failed to load Fennel compiler")
		return
	}

	// Test Fennel compilation
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
