package input

import "core:strings"
import "../types"
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
		case types.NodeHbox:
			aspect = n.aspect
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
) -> [dynamic]types.Dispatch_Event {
	dispatch: [dynamic]types.Dispatch_Event

	if !state.active || focused_idx < 0 || focused_idx >= len(nodes) {
		return dispatch
	}

	n, is_input := nodes[focused_idx].(types.NodeInput)
	if !is_input do return dispatch

	// Controlled sync
	controlled_sync(n.value)

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
			case .HOME:
				move_home(e.mods.shift)
			case .END:
				move_end(e.mods.shift)
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
			// Click-to-position cursor within focused input
			if focused_idx >= 0 && focused_idx < len(node_rects) {
				rect := node_rects[focused_idx]
				pt := rl.Vector2{e.x, e.y}
				if rl.CheckCollisionPointRec(pt, rect) {
					padding_l: f32 = 4
					click_x := e.x - rect.x - padding_l + state.scroll_offset
					font_size: f32 = 14
					f := rl.GetFontDefault()
					spacing := font_size / 10
					state.cursor = click_to_cursor(state.text[:], click_x, f, font_size, spacing)
					clear_selection()
				}
			}

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
