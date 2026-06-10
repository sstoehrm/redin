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

// Minimum on-screen thumb length in px — keeps the thumb grabbable when
// total content dwarfs the viewport.
SCROLLBAR_MIN_THUMB :: f32(20)

// Geometry of a scrollbar thumb along one axis.
Thumb_Geometry :: struct {
	pos:        f32, // absolute y (axis .Y) or x (axis .X) of the thumb start
	len:        f32, // thumb length along the axis
	max_travel: f32, // gutter length minus thumb length
	max_scroll: f32, // total content minus viewport
}

// Derive thumb geometry from the container's *content* rect (post-
// padding). The draw side (render.draw_box_children) and the hit-test
// side (apply_scrollbar) must both call this with the same rect — when
// they computed it independently, the hit-test side used the outer node
// rect and the drawn thumb disagreed with the clickable one by the
// padding amount.
thumb_geometry :: proc(
	content: rl.Rectangle,
	total:   f32,
	off:     f32,
	axis:    Scrollbar_Axis,
) -> Thumb_Geometry {
	viewport := axis == .Y ? content.height : content.width
	start    := axis == .Y ? content.y : content.x
	len        := max(viewport * (viewport / total), SCROLLBAR_MIN_THUMB)
	max_travel := viewport - len
	max_scroll := total - viewport
	ratio      := off / max_scroll if max_scroll > 0 else 0
	return {
		pos        = start + ratio * max_travel,
		len        = len,
		max_travel = max_travel,
		max_scroll = max_scroll,
	}
}

scrollbar: Scrollbar_State

// True for the rest of the frame after apply_scrollbar consumed a
// press. Other consumers (apply_listeners, process_text_selection,
// drag_update) skip their MouseEvent paths so a press on the bar
// doesn't also fire clicks / selections / app-drags on whatever sits
// behind the scrollbar.
scrollbar_consumed_press: bool

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
	// Content rects (post-padding), NOT outer node rects — the drawn bar
	// lives inside the content rect, so hit-testing must use the same
	// rect or drawn and clickable thumbs disagree on padded containers.
	content_rects:  []rl.Rectangle,
	scroll_info:    map[int]types.Scroll_Info,
	scroll_offsets: ^map[int]f32,
	theme:          map[string]types.Theme,
) -> (consumed_press: bool) {
	scrollbar_consumed_press = false

	// Re-flatten safety.
	if idx := scrollbar_container_idx(); idx >= 0 && idx >= len(content_rects) {
		scrollbar = nil
	}

	mouse := mouse_pos()
	bar_w := f32(scrollbar_bar_thickness(theme))

	// Currently dragging? Update offset based on cursor y.
	if drag_state, dragging := scrollbar.(Scrollbar_Dragging); dragging {
		container := content_rects[drag_state.container_idx]
		info := scroll_info[drag_state.container_idx]

		if drag_state.axis == .Y && info.total > container.height {
			g := thumb_geometry(container, info.total, 0, .Y)
			new_y_in_gutter := mouse.y - container.y - drag_state.grab_offset_in_thumb
			scroll_offsets[drag_state.container_idx] = drag_offset_for_thumb_y(
				new_y_in_gutter, g.max_travel, g.max_scroll,
			)
		} else if drag_state.axis == .X && info.total > container.width {
			g := thumb_geometry(container, info.total, 0, .X)
			new_x_in_gutter := mouse.x - container.x - drag_state.grab_offset_in_thumb
			scroll_offsets[drag_state.container_idx] = drag_offset_for_thumb_y(
				new_x_in_gutter, g.max_travel, g.max_scroll,
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
		if idx < 0 || idx >= len(content_rects) do continue
		container := content_rects[idx]
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

			container := content_rects[hovered_idx]
			info := scroll_info[hovered_idx]
			cur_off := scroll_offsets[hovered_idx]

			if hovered_axis == .Y {
				g := thumb_geometry(container, info.total, cur_off, .Y)

				if mouse.y >= g.pos && mouse.y <= g.pos + g.len {
					scrollbar = Scrollbar_Dragging{
						hovering = Scrollbar_Hovering{
							container_idx = hovered_idx, axis = .Y,
						},
						grab_offset_in_thumb = mouse.y - g.pos,
					}
				} else if mouse.y < g.pos {
					new := cur_off - container.height
					if new < 0 do new = 0
					scroll_offsets[hovered_idx] = new
				} else {
					new := cur_off + container.height
					if new > g.max_scroll do new = g.max_scroll
					scroll_offsets[hovered_idx] = new
				}
				consumed_press = true
			} else {
				g := thumb_geometry(container, info.total, cur_off, .X)

				if mouse.x >= g.pos && mouse.x <= g.pos + g.len {
					scrollbar = Scrollbar_Dragging{
						hovering = Scrollbar_Hovering{
							container_idx = hovered_idx, axis = .X,
						},
						grab_offset_in_thumb = mouse.x - g.pos,
					}
				} else if mouse.x < g.pos {
					new := cur_off - container.width
					if new < 0 do new = 0
					scroll_offsets[hovered_idx] = new
				} else {
					new := cur_off + container.width
					if new > g.max_scroll do new = g.max_scroll
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

	scrollbar_consumed_press = consumed_press
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
