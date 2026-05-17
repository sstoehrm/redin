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

apply_scrollbar :: proc(
	events:         []types.InputEvent,
	nodes:          []types.Node,
	node_rects:     []rl.Rectangle,
	scroll_info:    map[int]types.Scroll_Info,
	scroll_offsets: ^map[int]f32,
	theme:          map[string]types.Theme,
) -> (consumed_press: bool) {
	// Re-flatten safety: container_idx may no longer exist.
	if idx := scrollbar_container_idx(); idx >= 0 && idx >= len(node_rects) {
		scrollbar = nil
	}

	mouse := mouse_pos()

	// Pre-compute gutter rects for every scrollable node that needs a
	// visible bar. The map lookup is O(1) per node and bounded by the
	// number of nodes we already iterate, so the cost is dominated by
	// the existing per-frame layout pass.
	hovered_idx := -1
	hovered_axis: Scrollbar_Axis = .Y

	for idx, info in scroll_info {
		if idx < 0 || idx >= len(node_rects) do continue
		container := node_rects[idx]
		bar_w := f32(scrollbar_bar_thickness(theme))

		// Y axis: gutter is the right edge of the container, full height.
		if info.total > container.height {
			gutter := rl.Rectangle{
				container.x + container.width - bar_w - 4,  // -4 = hit-zone padding
				container.y,
				bar_w + 8,                                   // +8 = +4 on each side
				container.height,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .Y
				break
			}
		}
		// X axis: gutter is the bottom edge, full width.
		if info.total > container.width {
			gutter := rl.Rectangle{
				container.x,
				container.y + container.height - bar_w - 4,
				container.width,
				bar_w + 8,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .X
				break
			}
		}
	}

	if hovered_idx >= 0 {
		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = Scrollbar_Hovering{
				container_idx = hovered_idx,
				axis          = hovered_axis,
			}
		}
	} else {
		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = nil
		}
	}

	return false
}

scrollbar_bar_thickness :: proc(theme: map[string]types.Theme) -> int {
	if t, ok := theme["scrollbar"]; ok && t.border_width > 0 {
		return int(t.border_width)
	}
	return 4
}
