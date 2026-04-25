package types

import rl "vendor:raylib"

KeyMods :: struct {
	shift, ctrl, alt, super: bool,
}

KeyEvent :: struct {
	x, y: f32,
	key:  rl.KeyboardKey,
	mods: KeyMods,
}

CharEvent :: struct {
	x, y: f32,
	char: rune,
	mods: KeyMods,
}

MouseEvent :: struct {
	x, y:   f32,
	button: rl.MouseButton,
	mods:   KeyMods,
}

ResizeEvent :: struct {}

ScrollEvent :: struct {
	x, y:           f32, // mouse position
	delta_x, delta_y: f32, // wheel deltas (positive = right/up)
}

InputEvent :: union {
	KeyEvent,
	CharEvent,
	MouseEvent,
	ScrollEvent,
	ResizeEvent,
}

Change_Event :: struct {
	event_name: string,
	value:      string,
}

Key_Event_Dispatch :: struct {
	event_name: string,
	key:        string,
	mods:       KeyMods,
}

Click_Event :: struct {
	event_name: string,
	context_ref: i32, // Lua registry ref for click context (0 = none)
}

Drag_Event :: struct {
	event_name:  string,
	context_ref: i32, // Lua registry ref for drag payload
}

Drop_Event :: struct {
	event_name: string,
	from_ref:   i32, // Lua registry ref for drag source payload
	to_ref:     i32, // Lua registry ref for drop target payload
}

Dispatch_Event :: union {
	Change_Event,
	Key_Event_Dispatch,
	Click_Event,
	Drag_Event,
	Drop_Event,
}
