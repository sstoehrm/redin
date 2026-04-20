package input

import rl "vendor:raylib"
import "../types"
import text_pkg "../text"
import "../font"

@(private)
gesture: struct {
	anchor_offset: int,
	anchor_path:   [dynamic]u8,
	click_count:   int,
	last_click_t:  f64,
	active_drag:   bool,
}

// Main entry point. Run once per frame after apply_focus / process_drag.
process_text_selection :: proc(
	input_events: []types.InputEvent,
	listeners:    []types.Listener,
	nodes:        []types.Node,
	paths:        []types.Path,
	node_rects:   []rl.Rectangle,
	theme:        map[string]types.Theme,
) {
	// Phase A: fresh mouse-down. Scan events; for each LMB press, check
	// whether it lands on a selectable NodeText. If yes, start a selection.
	// If it lands on neither selectable text nor anything that would have
	// been handled by focus-enter (inputs already handled by apply_focus,
	// which clears text selection via focus_enter), clear any existing
	// text selection.
	for event in input_events {
		me, is_mouse := event.(types.MouseEvent)
		if !is_mouse || me.button != .LEFT do continue
		pt := rl.Vector2{me.x, me.y}

		hit := false
		for listener in listeners {
			tl, ok := listener.(types.Text_Select_Listener)
			if !ok do continue
			if tl.node_idx >= len(node_rects) do continue
			if !rl.CheckCollisionPointRec(pt, node_rects[tl.node_idx]) do continue

			text_node, is_text := nodes[tl.node_idx].(types.NodeText)
			if !is_text do continue

			offset := node_byte_offset_at(text_node, node_rects[tl.node_idx], pt, theme)

			clear(&gesture.anchor_path)
			p := paths[tl.node_idx]
			append(&gesture.anchor_path, ..p.value[:p.length])
			gesture.anchor_offset = offset
			gesture.active_drag = true

			set_text_selection(gesture.anchor_path[:], offset, offset)

			// Clear input focus for mutual exclusion (focus_enter is not
			// the code path here — apply_focus already ran for this event
			// and did not match an input listener, but being defensive).
			focused_idx = -1
			state.active = false

			hit = true
			break
		}

		// Click-elsewhere-to-clear: mouse-down missed all selectable text.
		// apply_focus will have already cleared for input clicks via
		// focus_enter. For a click over nothing interesting, drop any
		// existing text selection.
		if !hit && state.selection_kind == .Text {
			clear_text_selection()
		}
	}

	// Phase B: drag extension while LMB is held.
	if gesture.active_drag && rl.IsMouseButtonDown(.LEFT) {
		idx := find_node_by_path(paths, gesture.anchor_path[:])
		if idx < 0 || idx >= len(node_rects) {
			gesture.active_drag = false
		} else {
			text_node, is_text := nodes[idx].(types.NodeText)
			if is_text {
				mouse := rl.GetMousePosition()
				rect := node_rects[idx]
				offset := node_byte_offset_at(text_node, rect, mouse, theme)
				if offset == gesture.anchor_offset {
					// Collapsed to a caret; drop the selection range.
					state.selection_start = -1
					state.selection_end = -1
				} else if offset > gesture.anchor_offset {
					state.selection_start = gesture.anchor_offset
					state.selection_end = offset
				} else {
					state.selection_start = offset
					state.selection_end = gesture.anchor_offset
				}
			}
		}
	}

	// Phase C: mouse released — stop tracking drags.
	if gesture.active_drag && !rl.IsMouseButtonDown(.LEFT) {
		gesture.active_drag = false
	}
}

// Map a point inside a NodeText's rect to a byte offset in its content.
// Uses the same font/size resolution as render.
@(private)
node_byte_offset_at :: proc(
	n: types.NodeText,
	rect: rl.Rectangle,
	pt: rl.Vector2,
	theme: map[string]types.Theme,
) -> int {
	if len(n.content) == 0 do return 0

	font_size: f32 = 18
	font_name := "sans"
	font_weight: u8 = 0
	lh_ratio: f32 = 0
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do font_size = f32(t.font_size)
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
			lh_ratio = t.line_height
		}
	}
	f := font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
	spacing: f32 = 0
	lh := text_pkg.line_height(font_size, lh_ratio)

	lines := text_pkg.compute_lines(n.content, f, font_size, spacing, rect.width)
	defer delete(lines)

	rel_y := pt.y - rect.y
	line_idx := int(rel_y / lh)
	if line_idx < 0 do line_idx = 0
	if line_idx >= len(lines) do line_idx = len(lines) - 1
	line := lines[line_idx]

	return x_to_cursor_in_line(n.content, line, pt.x - rect.x, f, font_size, spacing)
}

// Called once per frame after bridge updates nodes / paths. If the stored
// selection path no longer resolves to a NodeText, or if its content has
// shrunk below selection_end, clear the selection. No-op when kind != .Text.
resolve_text_selection :: proc(paths: []types.Path, nodes: []types.Node) {
	if state.selection_kind != .Text do return
	idx := find_node_by_path(paths, state.selection_path[:])
	if idx < 0 {
		clear_text_selection()
		return
	}
	text_node, is_text := nodes[idx].(types.NodeText)
	if !is_text {
		clear_text_selection()
		return
	}
	if state.selection_end > len(text_node.content) {
		clear_text_selection()
	}
}

// Find the node whose path value equals `p`. Returns -1 if not found.
// Exported — also used by the per-frame resolver and the devserver's
// /selection handler to look up the current text-selection node.
find_node_by_path :: proc(paths: []types.Path, p: []u8) -> int {
	for i in 0 ..< len(paths) {
		if int(paths[i].length) != len(p) do continue
		match := true
		for j in 0 ..< len(p) {
			if paths[i].value[j] != p[j] {
				match = false
				break
			}
		}
		if match do return i
	}
	return -1
}
