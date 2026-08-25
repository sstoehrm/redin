package redin

import "core:testing"
import rl "vendor:raylib"
import "types"

// fit_dest_rect maps a texture (tw x th) into an element rect per the
// :fit attribute (spec 2026-08-25-texture-foundation).

@(test)
test_fit_stretch_fills_rect :: proc(t: ^testing.T) {
	r := rl.Rectangle{10, 20, 100, 50}
	testing.expect_value(t, fit_dest_rect(.stretch, r, 8, 8), r)
}

@(test)
test_fit_keep_centers_1to1 :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 50}
	d := fit_dest_rect(.keep, r, 20, 10)
	testing.expect_value(t, d, rl.Rectangle{40, 20, 20, 10})
}

@(test)
test_fit_stretch_x_preserves_aspect :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 100}
	// 50x25 texture -> fill width 100 => height 50, centered vertically.
	d := fit_dest_rect(.stretchX, r, 50, 25)
	testing.expect_value(t, d, rl.Rectangle{0, 25, 100, 50})
}

@(test)
test_fit_stretch_y_preserves_aspect :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 100}
	// 25x50 texture -> fill height 100 => width 50, centered horizontally.
	d := fit_dest_rect(.stretchY, r, 25, 50)
	testing.expect_value(t, d, rl.Rectangle{25, 0, 50, 100})
}

@(test)
test_fit_degenerate_texture_falls_back_to_rect :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 100}
	testing.expect_value(t, fit_dest_rect(.stretchX, r, 0, 0), r)
}
