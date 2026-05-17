package input

import "core:testing"

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
