package input

import rl "vendor:raylib"

// Test-only override of raylib mouse polling. Driven by the dev server's
// /input/* endpoints; off in normal runs.
//
// Position-only changes do not synthesise events (matches real input).
// Button transitions go through `pending_press_*` / `pending_release_*`
// which act as one-shot edges: set when the dev server flips a button,
// consumed (and cleared) by `is_mouse_button_pressed/released` exactly
// once. `is_mouse_button_down` reflects the held state continuously.
Mouse_Override :: struct {
	active:        bool,
	pos:           rl.Vector2,
	button_left:   bool,
	button_right:  bool,
	button_middle: bool,

	pending_press_left,    pending_release_left:    bool,
	pending_press_right,   pending_release_right:   bool,
	pending_press_middle,  pending_release_middle:  bool,
}

override: Mouse_Override

mouse_pos :: proc() -> rl.Vector2 {
	if override.active do return override.pos
	return rl.GetMousePosition()
}

is_mouse_button_down :: proc(btn: rl.MouseButton) -> bool {
	if override.active {
		switch btn {
		case .LEFT:    return override.button_left
		case .RIGHT:   return override.button_right
		case .MIDDLE:  return override.button_middle
		case .SIDE, .EXTRA, .FORWARD, .BACK: return false
		}
		return false
	}
	return rl.IsMouseButtonDown(btn)
}

is_mouse_button_pressed :: proc(btn: rl.MouseButton) -> bool {
	if override.active {
		switch btn {
		case .LEFT:
			r := override.pending_press_left
			override.pending_press_left = false
			return r
		case .RIGHT:
			r := override.pending_press_right
			override.pending_press_right = false
			return r
		case .MIDDLE:
			r := override.pending_press_middle
			override.pending_press_middle = false
			return r
		case .SIDE, .EXTRA, .FORWARD, .BACK: return false
		}
		return false
	}
	return rl.IsMouseButtonPressed(btn)
}

is_mouse_button_released :: proc(btn: rl.MouseButton) -> bool {
	if override.active {
		switch btn {
		case .LEFT:
			r := override.pending_release_left
			override.pending_release_left = false
			return r
		case .RIGHT:
			r := override.pending_release_right
			override.pending_release_right = false
			return r
		case .MIDDLE:
			r := override.pending_release_middle
			override.pending_release_middle = false
			return r
		case .SIDE, .EXTRA, .FORWARD, .BACK: return false
		}
		return false
	}
	return rl.IsMouseButtonReleased(btn)
}
