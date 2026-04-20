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

	// Phase B (drag) + Phase C (release) are Task 8.
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
	spacing := max(font_size / 10, 1)
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
