package input

import "core:strings"
import "../types"
import text_pkg "../text"
import font "../font"
import rl "vendor:raylib"

// Currently focused node index, -1 means none.
focused_idx: int = -1

extract_listeners :: proc(
	paths: [dynamic]types.Path,
	nodes: [dynamic]types.Node,
	theme: map[string]types.Theme,
) -> [dynamic]types.Listener {
	listeners: [dynamic]types.Listener

	for node, idx in nodes {
		aspect: string
		switch n in node {
		case types.NodeInput:
			aspect = n.aspect
			append(&listeners, types.Listener(types.FocusListener{node_idx = idx}))
			if len(n.change) > 0 {
				append(&listeners, types.Listener(types.ChangeListener{node_idx = idx}))
			}
			if len(n.key) > 0 {
				append(&listeners, types.Listener(types.KeyListener{node_idx = idx}))
			}
		case types.NodeButton:
			aspect = n.aspect
			if len(n.click) > 0 {
				append(&listeners, types.Listener(types.ClickListener{node_idx = idx}))
			}
		case types.NodeCanvas:
			aspect = n.aspect
		case types.NodeVbox:
			aspect = n.aspect
			if len(n.draggable_group) > 0 {
				append(&listeners, types.Listener(types.DragListener{node_idx = idx}))
			}
			if len(n.dropable_group) > 0 {
				append(&listeners, types.Listener(types.DropListener{node_idx = idx, group = n.dropable_group}))
			}
		case types.NodeHbox:
			aspect = n.aspect
			if len(n.draggable_group) > 0 {
				append(&listeners, types.Listener(types.DragListener{node_idx = idx}))
			}
			if len(n.dropable_group) > 0 {
				append(&listeners, types.Listener(types.DropListener{node_idx = idx, group = n.dropable_group}))
			}
		case types.NodeText:
			aspect = n.aspect
		case types.NodeImage:
			aspect = n.aspect
		case types.NodePopout:
			aspect = n.aspect
		case types.NodeModal:
			aspect = n.aspect
		case types.NodeStack:
		}

		if len(aspect) > 0 {
			hover_key := strings.concatenate({aspect, "#hover"}, context.temp_allocator)
			if hover_key in theme {
				append(&listeners, types.Listener(types.HoverListener{node_idx = idx}))
			}
			is_input := false
			if _, ok := node.(types.NodeInput); ok {
				is_input = true
			}
			if !is_input {
				focus_key := strings.concatenate({aspect, "#focus"}, context.temp_allocator)
				if focus_key in theme {
					append(&listeners, types.Listener(types.FocusListener{node_idx = idx}))
				}
			}
		}
	}

	return listeners
}

poll :: proc() -> [dynamic]types.InputEvent {
	events: [dynamic]types.InputEvent

	mods := types.KeyMods {
		shift = rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT),
		ctrl  = rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL),
		alt   = rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT),
		super = rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER),
	}

	mouse := rl.GetMousePosition()

	key := rl.GetKeyPressed()
	for key != .KEY_NULL {
		append(
			&events,
			types.InputEvent(types.KeyEvent{x = mouse.x, y = mouse.y, key = key, mods = mods}),
		)
		key = rl.GetKeyPressed()
	}

	// Repeat events for held editing keys (backspace, delete, arrows, etc.)
	repeat_keys := [?]rl.KeyboardKey{
		.BACKSPACE, .DELETE, .LEFT, .RIGHT, .UP, .DOWN, .HOME, .END,
		.PAGE_UP, .PAGE_DOWN, .TAB, .ENTER,
	}
	for rk in repeat_keys {
		if rl.IsKeyPressedRepeat(rk) {
			append(
				&events,
				types.InputEvent(types.KeyEvent{x = mouse.x, y = mouse.y, key = rk, mods = mods}),
			)
		}
	}

	ch := rl.GetCharPressed()
	for ch != 0 {
		append(
			&events,
			types.InputEvent(types.CharEvent{x = mouse.x, y = mouse.y, char = ch, mods = mods}),
		)
		ch = rl.GetCharPressed()
	}

	buttons := [?]rl.MouseButton{.LEFT, .RIGHT, .MIDDLE}
	for btn in buttons {
		if rl.IsMouseButtonPressed(btn) {
			append(
				&events,
				types.InputEvent(
					types.MouseEvent{x = mouse.x, y = mouse.y, button = btn, mods = mods},
				),
			)
		}
	}

	wheel := rl.GetMouseWheelMoveV()
	dx, dy := wheel.x, wheel.y
	// Shift promotes vertical wheel to horizontal scroll.
	if mods.shift && dy != 0 && dx == 0 {
		dx = dy
		dy = 0
	}
	if dx != 0 || dy != 0 {
		append(&events, types.InputEvent(types.ScrollEvent{
			x = mouse.x, y = mouse.y, delta_x = dx, delta_y = dy,
		}))
	}

	if rl.IsWindowResized() {
		append(&events, types.InputEvent(types.ResizeEvent{}))
	}

	return events
}

// Process user events for the focused input. Applies edits to Input_State
// and returns Dispatch_Events for Fennel.
process_user_events :: proc(
	user_events: []types.UserEvent,
	input_events: []types.InputEvent,
	nodes: []types.Node,
	node_rects: []rl.Rectangle,
	theme: map[string]types.Theme,
) -> [dynamic]types.Dispatch_Event {
	dispatch: [dynamic]types.Dispatch_Event

	// Handle click events for buttons (independent of focus state)
	for ue in user_events {
		if ue.event != .CLICK do continue
		if ue.node_idx < 0 || ue.node_idx >= len(nodes) do continue
		if btn, ok := nodes[ue.node_idx].(types.NodeButton); ok && len(btn.click) > 0 {
			append(&dispatch, types.Dispatch_Event(types.Click_Event{
				event_name  = btn.click,
				context_ref = btn.click_ctx,
			}))
		}
	}

	if !state.active || focused_idx < 0 || focused_idx >= len(nodes) {
		return dispatch
	}

	n, is_input := nodes[focused_idx].(types.NodeInput)
	if !is_input do return dispatch

	// Controlled sync
	controlled_sync(n.value)

	// Compute text layout for multiline navigation
	inp_font_name := "sans"
	inp_font_size: f32 = 14
	inp_font_weight: u8 = 0
	inp_padding_l: f32 = 4
	inp_padding_r: f32 = 4
	inp_lh_ratio: f32 = 0
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do inp_font_size = f32(t.font_size)
			if len(t.font) > 0 do inp_font_name = t.font
			inp_font_weight = t.weight
			if t.padding[3] > 0 do inp_padding_l = f32(t.padding[3])
			if t.padding[1] > 0 do inp_padding_r = f32(t.padding[1])
			inp_lh_ratio = t.line_height
		}
	}
	inp_font := font.get(inp_font_name, font.style_from_weight(font.Font_Weight(inp_font_weight)))
	inp_spacing: f32 = 0
	inp_content_w: f32 = 0
	if focused_idx >= 0 && focused_idx < len(node_rects) {
		inp_content_w = node_rects[focused_idx].width - inp_padding_l - inp_padding_r
	}
	text_str := get_text()
	layout_lines := text_pkg.compute_lines(text_str, inp_font, inp_font_size, inp_spacing, inp_content_w)
	defer delete(layout_lines)

	text_changed := false

	for event in input_events {
		switch e in event {
		case types.CharEvent:
			if len(n.change) == 0 do continue
			insert_char(e.char)
			text_changed = true

		case types.KeyEvent:
			// Dispatch key event to Fennel if node has :key attribute
			if len(n.key) > 0 {
				append(&dispatch, types.Dispatch_Event(types.Key_Event_Dispatch{
					event_name = n.key,
					key        = key_to_string_input(e.key),
					mods       = e.mods,
				}))
			}

			// Process editing keys
			#partial switch e.key {
			case .ENTER:
				insert_char('\n')
				text_changed = true
			case .BACKSPACE:
				if e.mods.ctrl {
					delete_back_word()
				} else {
					delete_back_char()
				}
				text_changed = true
			case .DELETE:
				if e.mods.ctrl {
					delete_forward_word()
				} else {
					delete_forward_char()
				}
				text_changed = true
			case .LEFT:
				if e.mods.ctrl {
					move_word_left(e.mods.shift)
				} else {
					move_left(e.mods.shift)
				}
			case .RIGHT:
				if e.mods.ctrl {
					move_word_right(e.mods.shift)
				} else {
					move_right(e.mods.shift)
				}
			case .UP:
				// Recompute layout since text_str may have changed
				text_str = get_text()
				delete(layout_lines)
				layout_lines = text_pkg.compute_lines(text_str, inp_font, inp_font_size, inp_spacing, inp_content_w)
				move_up(layout_lines[:], text_str, inp_font, inp_font_size, inp_spacing, e.mods.shift)
			case .DOWN:
				text_str = get_text()
				delete(layout_lines)
				layout_lines = text_pkg.compute_lines(text_str, inp_font, inp_font_size, inp_spacing, inp_content_w)
				move_down(layout_lines[:], text_str, inp_font, inp_font_size, inp_spacing, e.mods.shift)
			case .HOME:
				if e.mods.ctrl {
					move_home(e.mods.shift)
				} else {
					text_str = get_text()
					delete(layout_lines)
					layout_lines = text_pkg.compute_lines(text_str, inp_font, inp_font_size, inp_spacing, inp_content_w)
					move_home_line(layout_lines[:], e.mods.shift)
				}
			case .END:
				if e.mods.ctrl {
					move_end(e.mods.shift)
				} else {
					text_str = get_text()
					delete(layout_lines)
					layout_lines = text_pkg.compute_lines(text_str, inp_font, inp_font_size, inp_spacing, inp_content_w)
					move_end_line(layout_lines[:], e.mods.shift)
				}
			case .A:
				if e.mods.ctrl do select_all()
			case .C:
				if e.mods.ctrl do copy_selection()
			case .X:
				if e.mods.ctrl {
					cut_selection()
					text_changed = true
				}
			case .V:
				if e.mods.ctrl {
					paste()
					text_changed = true
				}
			case:
			}

		case types.MouseEvent:
			if focused_idx >= 0 && focused_idx < len(node_rects) {
				rect := node_rects[focused_idx]
				pt := rl.Vector2{e.x, e.y}
				if rl.CheckCollisionPointRec(pt, rect) {
					click_x := e.x - rect.x - inp_padding_l
					click_y := e.y - rect.y
					lh := text_pkg.line_height(inp_font_size, inp_lh_ratio)
					text_str = get_text()
					delete(layout_lines)
					layout_lines = text_pkg.compute_lines(text_str, inp_font, inp_font_size, inp_spacing, inp_content_w)
					state.cursor = text_pkg.point_to_cursor(
						layout_lines[:], text_str,
						click_x, click_y,
						inp_font, inp_font_size, inp_spacing, lh,
						state.scroll_offset_x, state.scroll_offset_y,
					)
					clear_selection()
				}
			}

		case types.ScrollEvent:
		case types.ResizeEvent:
		}
	}

	// Dispatch change event if text was modified
	if text_changed && len(n.change) > 0 {
		current := get_text()
		append(&dispatch, types.Dispatch_Event(types.Change_Event{
			event_name = n.change,
			value      = current,
		}))
		if len(state.last_dispatched) > 0 {
			delete(state.last_dispatched)
		}
		state.last_dispatched = strings_clone(current)
	}

	return dispatch
}

key_to_string_input :: proc(key: rl.KeyboardKey) -> string {
	#partial switch key {
	case .ENTER:     return "enter"
	case .ESCAPE:    return "escape"
	case .BACKSPACE: return "backspace"
	case .TAB:       return "tab"
	case .SPACE:     return "space"
	case .UP:        return "up"
	case .DOWN:      return "down"
	case .LEFT:      return "left"
	case .RIGHT:     return "right"
	case .DELETE:    return "delete"
	case .HOME:      return "home"
	case .END:       return "end"
	case .PAGE_UP:   return "pageup"
	case .PAGE_DOWN: return "pagedown"
	case:            return "unknown"
	}
}
