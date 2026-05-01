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

			offset := node_byte_offset_at(tl.node_idx, text_node, node_rects[tl.node_idx], pt, theme)

			// Shift-click extends the existing selection to the new offset within
			// the same node. The anchor remains at its original byte.
			if me.mods.shift && state.selection_kind == .Text {
				// Only extend if this click landed on the same node.
				same_node := len(gesture.anchor_path) == int(paths[tl.node_idx].length)
				if same_node {
					for j in 0 ..< len(gesture.anchor_path) {
						if gesture.anchor_path[j] != paths[tl.node_idx].value[j] {
							same_node = false
							break
						}
					}
				}
				if same_node {
					state.selection_end = offset
					gesture.active_drag = true
					hit = true
					break
				}
			}

			// Track click cadence. Promotes on rapid re-click within the same node.
			now := rl.GetTime()
			if now - gesture.last_click_t < 0.4 && gesture.click_count > 0 {
				gesture.click_count += 1
				if gesture.click_count > 3 do gesture.click_count = 3
			} else {
				gesture.click_count = 1
			}
			gesture.last_click_t = now

			clear(&gesture.anchor_path)
			p := paths[tl.node_idx]
			append(&gesture.anchor_path, ..p.value[:p.length])
			gesture.active_drag = true

			lo, hi := offset, offset
			switch gesture.click_count {
			case 2:
				content_bytes := transmute([]u8)text_node.content
				lo = prev_word(content_bytes, offset)
				hi = next_word(content_bytes, offset)
			case 3:
				// Whole wrapped line at this offset. Reuse the cached
				// wrap from layout/draw — same (idx, width) key.
				f := resolve_font(text_node, theme)
				fs := resolve_font_size(text_node, theme)
				width := node_rects[tl.node_idx].width
				lines: []text_pkg.Text_Line
				fresh: [dynamic]text_pkg.Text_Line
				owns := false
				if cached, ok := text_pkg.lookup_lines(tl.node_idx, width); ok {
					lines = cached
				} else {
					fresh = text_pkg.compute_lines(text_node.content, f, fs, 0, width)
					lines = fresh[:]
					owns = true
				}
				defer if owns do delete(fresh)
				if len(lines) > 0 {
					line_idx, _ := text_pkg.cursor_to_line(lines, offset)
					lo = lines[line_idx].start
					hi = lines[line_idx].end
				}
			}
			gesture.anchor_offset = lo
			set_text_selection(gesture.anchor_path[:], lo, hi)

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
	if gesture.active_drag && is_mouse_button_down(.LEFT) {
		idx := find_node_by_path(paths, gesture.anchor_path[:])
		if idx < 0 || idx >= len(node_rects) {
			gesture.active_drag = false
		} else {
			text_node, is_text := nodes[idx].(types.NodeText)
			if is_text {
				mouse := mouse_pos()
				rect := node_rects[idx]
				offset := node_byte_offset_at(idx, text_node, rect, mouse, theme)
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
	if gesture.active_drag && !is_mouse_button_down(.LEFT) {
		gesture.active_drag = false
	}
}

// Map a point inside a NodeText's rect to a byte offset in its content.
// Uses the same font/size resolution as render.
@(private)
node_byte_offset_at :: proc(
	node_idx: int,
	n: types.NodeText,
	rect: rl.Rectangle,
	pt: rl.Vector2,
	theme: map[string]types.Theme,
) -> int {
	if len(n.content) == 0 do return 0

	f := resolve_font(n, theme)
	font_size := resolve_font_size(n, theme)
	spacing: f32 = 0
	lh_ratio: f32 = 0
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			lh_ratio = t.line_height
		}
	}
	lh := text_pkg.line_height(font_size, lh_ratio)

	// Prefer the cache populated by layout/draw at the same (idx, width).
	lines: []text_pkg.Text_Line
	fresh: [dynamic]text_pkg.Text_Line
	owns := false
	if cached, ok := text_pkg.lookup_lines(node_idx, rect.width); ok {
		lines = cached
	} else {
		fresh = text_pkg.compute_lines(n.content, f, font_size, spacing, rect.width)
		lines = fresh[:]
		owns = true
	}
	defer if owns do delete(fresh)

	rel_y := pt.y - rect.y
	line_idx := int(rel_y / lh)
	if line_idx < 0 do line_idx = 0
	if line_idx >= len(lines) do line_idx = len(lines) - 1
	line := lines[line_idx]

	return x_to_cursor_in_line(n.content, line, pt.x - rect.x, f, font_size, spacing)
}

@(private)
resolve_font :: proc(n: types.NodeText, theme: map[string]types.Theme) -> rl.Font {
	font_name := "sans"
	font_weight: u8 = 0
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
		}
	}
	return font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
}

@(private)
resolve_font_size :: proc(n: types.NodeText, theme: map[string]types.Theme) -> f32 {
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do return f32(t.font_size)
		}
	}
	return 18
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
