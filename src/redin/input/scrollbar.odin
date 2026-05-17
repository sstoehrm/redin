package input

import "../types"
import rl "vendor:raylib"

Scrollbar_Axis :: enum { Y, X }

Scrollbar_Hovering :: struct {
	container_idx: int,
	axis:          Scrollbar_Axis,
}

Scrollbar_Dragging :: struct {
	using hovering:       Scrollbar_Hovering,
	// Cursor's offset from the thumb's top (or left) edge at drag-start.
	// Holding this constant during drag keeps the thumb from snapping
	// under the cursor.
	grab_offset_in_thumb: f32,
}

Scrollbar_State :: union { Scrollbar_Hovering, Scrollbar_Dragging }

scrollbar: Scrollbar_State

// container_idx of the scrollbar state, regardless of variant.
// Returns -1 if scrollbar is idle.
scrollbar_container_idx :: proc() -> int {
	switch s in scrollbar {
	case Scrollbar_Hovering: return s.container_idx
	case Scrollbar_Dragging: return s.container_idx
	}
	return -1
}

// Stub: implemented in Task 5/6/7.
apply_scrollbar :: proc(
	events:         []types.InputEvent,
	nodes:          []types.Node,
	node_rects:     []rl.Rectangle,
	scroll_info:    map[int]types.Scroll_Info,
	scroll_offsets: ^map[int]f32,
	theme:          map[string]types.Theme,
) -> (consumed_press: bool) {
	return false
}
