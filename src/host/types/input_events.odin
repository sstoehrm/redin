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

InputEvent :: union {
	KeyEvent,
	CharEvent,
	MouseEvent,
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

Dispatch_Event :: union {
	Change_Event,
	Key_Event_Dispatch,
}
