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
	// Re-flatten safety.
	if idx := scrollbar_container_idx(); idx >= 0 && idx >= len(node_rects) {
		scrollbar = nil
	}

	mouse := mouse_pos()
	bar_w := f32(scrollbar_bar_thickness(theme))

	// Currently dragging? Update offset based on cursor y.
	if drag_state, dragging := scrollbar.(Scrollbar_Dragging); dragging {
		container := node_rects[drag_state.container_idx]
		info := scroll_info[drag_state.container_idx]

		if drag_state.axis == .Y && info.total > container.height {
			gutter_top := container.y
			thumb_h    := max(container.height * (container.height / info.total), 20)
			max_thumb  := container.height - thumb_h
			max_scroll := info.total - container.height
			new_y_in_gutter := mouse.y - gutter_top - drag_state.grab_offset_in_thumb
			scroll_offsets[drag_state.container_idx] = drag_offset_for_thumb_y(
				new_y_in_gutter, max_thumb, max_scroll,
			)
		} else if drag_state.axis == .X && info.total > container.width {
			gutter_left := container.x
			thumb_w    := max(container.width * (container.width / info.total), 20)
			max_thumb  := container.width - thumb_w
			max_scroll := info.total - container.width
			new_x_in_gutter := mouse.x - gutter_left - drag_state.grab_offset_in_thumb
			scroll_offsets[drag_state.container_idx] = drag_offset_for_thumb_y(
				new_x_in_gutter, max_thumb, max_scroll,
			)
		}

		// Release ends the drag.
		if is_mouse_button_released(.LEFT) {
			scrollbar = Scrollbar_Hovering{
				container_idx = drag_state.container_idx,
				axis          = drag_state.axis,
			}
		}
		return false  // consumed_press is for the press frame only
	}

	// Hit-test gutters for hover + press.
	hovered_idx := -1
	hovered_axis: Scrollbar_Axis = .Y
	for idx, info in scroll_info {
		if idx < 0 || idx >= len(node_rects) do continue
		container := node_rects[idx]
		if info.total > container.height {
			gutter := rl.Rectangle{
				container.x + container.width - bar_w - 4,
				container.y, bar_w + 8, container.height,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .Y
				break
			}
		}
		if info.total > container.width {
			gutter := rl.Rectangle{
				container.x, container.y + container.height - bar_w - 4,
				container.width, bar_w + 8,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .X
				break
			}
		}
	}

	// Press on a gutter → start drag (if on thumb) or page jump (if outside).
	if hovered_idx >= 0 {
		for event in events {
			me, ok := event.(types.MouseEvent)
			if !ok || me.button != .LEFT do continue

			container := node_rects[hovered_idx]
			info := scroll_info[hovered_idx]
			cur_off := scroll_offsets[hovered_idx]

			if hovered_axis == .Y {
				gutter_top := container.y
				thumb_h    := max(container.height * (container.height / info.total), 20)
				max_thumb  := container.height - thumb_h
				max_scroll := info.total - container.height
				thumb_y    := gutter_top + (cur_off / max_scroll if max_scroll > 0 else 0) * max_thumb

				if mouse.y >= thumb_y && mouse.y <= thumb_y + thumb_h {
					scrollbar = Scrollbar_Dragging{
						hovering = Scrollbar_Hovering{
							container_idx = hovered_idx, axis = .Y,
						},
						grab_offset_in_thumb = mouse.y - thumb_y,
					}
				} else if mouse.y < thumb_y {
					new := cur_off - container.height
					if new < 0 do new = 0
					scroll_offsets[hovered_idx] = new
				} else {
					new := cur_off + container.height
					if new > max_scroll do new = max_scroll
					scroll_offsets[hovered_idx] = new
				}
				consumed_press = true
			} else {
				gutter_left := container.x
				thumb_w    := max(container.width * (container.width / info.total), 20)
				max_thumb  := container.width - thumb_w
				max_scroll := info.total - container.width
				thumb_x    := gutter_left + (cur_off / max_scroll if max_scroll > 0 else 0) * max_thumb

				if mouse.x >= thumb_x && mouse.x <= thumb_x + thumb_w {
					scrollbar = Scrollbar_Dragging{
						hovering = Scrollbar_Hovering{
							container_idx = hovered_idx, axis = .X,
						},
						grab_offset_in_thumb = mouse.x - thumb_x,
					}
				} else if mouse.x < thumb_x {
					new := cur_off - container.width
					if new < 0 do new = 0
					scroll_offsets[hovered_idx] = new
				} else {
					new := cur_off + container.width
					if new > max_scroll do new = max_scroll
					scroll_offsets[hovered_idx] = new
				}
				consumed_press = true
			}
			break  // only first press matters
		}

		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = Scrollbar_Hovering{
				container_idx = hovered_idx, axis = hovered_axis,
			}
		}
	} else {
		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = nil
		}
	}

	return consumed_press
}

scrollbar_bar_thickness :: proc(theme: map[string]types.Theme) -> int {
	if t, ok := theme["scrollbar"]; ok && t.border_width > 0 {
		return int(t.border_width)
	}
	return 4
}

// Pure drag-math: map a new thumb top-y (relative to gutter top) to the
// corresponding scroll offset. Clamps both endpoints. Pure function;
// tested in scrollbar_test.odin.
drag_offset_for_thumb_y :: proc(
	new_thumb_y_in_gutter: f32,
	max_thumb_travel: f32,
	max_scroll: f32,
) -> f32 {
	if max_thumb_travel <= 0 || max_scroll <= 0 do return 0
	y := new_thumb_y_in_gutter
	if y < 0                 do y = 0
	if y > max_thumb_travel  do y = max_thumb_travel
	return y / max_thumb_travel * max_scroll
}
