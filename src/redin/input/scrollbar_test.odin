package input

import "core:testing"
import rl "vendor:raylib"

// --- thumb_geometry ---
// One shared derivation for the draw side (render.draw_box_children) and
// the hit-test side (apply_scrollbar). Both must compute the thumb from
// the container's *content* rect (post-padding); the original bug was the
// hit-test side using the outer rect, so on padded containers the drawn
// thumb and the clickable thumb disagreed by the padding amount.

expect_close :: proc(t: ^testing.T, got, want: f32, loc := #caller_location) {
	testing.expectf(t, abs(got - want) < 0.001, "expected %v, got %v", want, got, loc = loc)
}

@(test)
test_thumb_geometry_y_proportional :: proc(t: ^testing.T) {
	// Content rect 200px tall at y=70 (a 240px container with 20px
	// padding), total content 900.
	content := rl.Rectangle{20, 70, 1240, 200}
	g := thumb_geometry(content, 900, 0, .Y)
	expect_close(t, g.len, 200.0 * (200.0 / 900.0))
	testing.expect_value(t, g.pos, f32(70))
	testing.expect_value(t, g.max_travel, f32(200) - g.len)
	testing.expect_value(t, g.max_scroll, f32(700))
}

@(test)
test_thumb_geometry_y_offset_positions_thumb :: proc(t: ^testing.T) {
	content := rl.Rectangle{20, 70, 1240, 200}
	g := thumb_geometry(content, 900, 700, .Y) // fully scrolled
	testing.expect_value(t, g.pos, f32(70) + g.max_travel)
}

@(test)
test_thumb_geometry_min_thumb_clamp :: proc(t: ^testing.T) {
	content := rl.Rectangle{0, 0, 100, 100}
	g := thumb_geometry(content, 10000, 0, .Y)
	testing.expect_value(t, g.len, SCROLLBAR_MIN_THUMB)
}

@(test)
test_thumb_geometry_x_axis :: proc(t: ^testing.T) {
	content := rl.Rectangle{30, 0, 400, 50}
	g := thumb_geometry(content, 800, 200, .X)
	expect_close(t, g.len, 400.0 * (400.0 / 800.0))
	testing.expect_value(t, g.max_scroll, f32(400))
	// off=200 of max 400 → thumb at half its travel, from content.x.
	expect_close(t, g.pos, 30.0 + 0.5 * g.max_travel)
}

@(test)
test_drag_math_proportional :: proc(t: ^testing.T) {
	// Gutter at y=50..250 (h=200). Total content 900 → max_scroll=700.
	// Thumb height = 200 * (200/900) ≈ 44.44. max_thumb_y = 250 - 44.44.
	// Cursor drags from thumb-center down by 50px. Expected offset
	// delta: 50 / (200 - 44.44) * 700 ≈ 224.9.
	container_h: f32 = 200
	total: f32       = 900
	thumb_h          := f32(container_h * (container_h / total))
	max_thumb_travel := container_h - thumb_h
	max_scroll       := total - container_h

	new_thumb_y := f32(50)              // dragged 50px from gutter top
	expected    := new_thumb_y / max_thumb_travel * max_scroll
	got         := drag_offset_for_thumb_y(new_thumb_y, max_thumb_travel, max_scroll)

	testing.expect_value(t, got, expected)
}

@(test)
test_drag_math_clamps_at_zero :: proc(t: ^testing.T) {
	// Cursor above the gutter → thumb_y clamped to 0 → offset 0.
	got := drag_offset_for_thumb_y(-10, 155.56, 700)
	testing.expect_value(t, got, f32(0))
}

@(test)
test_drag_math_clamps_at_max :: proc(t: ^testing.T) {
	// Cursor past the gutter bottom → thumb_y clamped to max_thumb_travel
	// → offset = max_scroll.
	got := drag_offset_for_thumb_y(999, 155.56, 700)
	testing.expect_value(t, got, f32(700))
}
