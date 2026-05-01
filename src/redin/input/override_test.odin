package input

import "core:testing"
import rl "vendor:raylib"

// These tests mutate the package-level `override` variable, so they must
// be run sequentially. Use:
//
//   odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit \
//       -define:ODIN_TEST_THREADS=1
//
// Without the flag, parallel test execution races on the shared global
// and yields intermittent failures.

@(test)
test_mouse_pos_falls_back_to_raylib_when_inactive :: proc(t: ^testing.T) {
	override = Mouse_Override{}
	// Cannot easily mock rl.GetMousePosition; just assert active=false path
	// returns the raylib value (whatever it is) by reading both.
	got := mouse_pos()
	want := rl.GetMousePosition()
	testing.expect_value(t, got, want)
}

@(test)
test_mouse_pos_uses_override_when_active :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, pos = {123, 456}}
	got := mouse_pos()
	testing.expect_value(t, got.x, f32(123))
	testing.expect_value(t, got.y, f32(456))
	override = Mouse_Override{}
}

@(test)
test_is_mouse_button_down_uses_override :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, button_left = true}
	testing.expect(t, is_mouse_button_down(.LEFT))
	testing.expect(t, !is_mouse_button_down(.RIGHT))
	override = Mouse_Override{}
}

@(test)
test_pressed_clears_pending_flag :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, pending_press_left = true}
	testing.expect(t, is_mouse_button_pressed(.LEFT))
	testing.expect(t, !override.pending_press_left,
		"pending_press_left should clear after read")
	testing.expect(t, !is_mouse_button_pressed(.LEFT),
		"second read returns false")
	override = Mouse_Override{}
}

@(test)
test_released_clears_pending_flag :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, pending_release_left = true}
	testing.expect(t, is_mouse_button_released(.LEFT))
	testing.expect(t, !override.pending_release_left)
	override = Mouse_Override{}
}

@(test)
test_pending_flags_do_not_bleed_across_buttons :: proc(t: ^testing.T) {
	override = Mouse_Override{
		active             = true,
		pending_press_left = true,
	}
	// Reading RIGHT must not consume LEFT's pending flag.
	testing.expect(t, !is_mouse_button_pressed(.RIGHT))
	testing.expect(t,  override.pending_press_left,
		"reading RIGHT must not clear LEFT pending_press")
	// Same for MIDDLE.
	testing.expect(t, !is_mouse_button_pressed(.MIDDLE))
	testing.expect(t,  override.pending_press_left)
	// LEFT itself still works.
	testing.expect(t,  is_mouse_button_pressed(.LEFT))
	testing.expect(t, !override.pending_press_left)
	override = Mouse_Override{}
}
