package input

import "../types"
import rl "vendor:raylib"

get_user_events :: proc(
	input_events: [dynamic]types.InputEvent,
	listeners: [dynamic]types.Listener,
	node_rects: []rl.Rectangle,
) -> [dynamic]types.UserEvent {
	user_events: [dynamic]types.UserEvent

	if focused_idx >= len(node_rects) {
		focused_idx = -1
	}

	mouse := mouse_pos()

	for listener in listeners {
		if hl, ok := listener.(types.HoverListener); ok {
			if hl.node_idx < len(node_rects) &&
			   rl.CheckCollisionPointRec(mouse, node_rects[hl.node_idx]) {
				append(
					&user_events,
					types.UserEvent{event = .HOVER, node_idx = hl.node_idx},
				)
			}
		}
	}

	for event in input_events {
		switch e in event {
		case types.MouseEvent:
			if e.button != .LEFT do continue
			if is_dragging() do continue
			pt := rl.Vector2{e.x, e.y}

			// Deepest node wins: compute the innermost listener-bearing
			// node under the pointer, then fire only that node's
			// listeners. Ancestor click/focus listeners are suppressed.
			// Hover is multi-fire and stays in its own loop above.
			winner := deepest_listener_idx(listeners[:], node_rects, pt)
			if winner < 0 do continue

			for listener in listeners {
				switch l in listener {
				case types.ClickListener:
					if l.node_idx == winner {
						append(&user_events, types.UserEvent{event = .CLICK, node_idx = winner})
					}
				case types.FocusListener:
					if l.node_idx == winner {
						append(&user_events, types.UserEvent{event = .FOCUS, node_idx = winner})
					}
				case types.HoverListener, types.KeyListener, types.ChangeListener,
				     types.DragListener, types.DropListener, types.Text_Select_Listener,
				     types.DragOverListener:
				}
			}

		case types.KeyEvent:
			if focused_idx >= 0 {
				for listener in listeners {
					if kl, ok := listener.(types.KeyListener); ok && kl.node_idx == focused_idx {
						append(
							&user_events,
							types.UserEvent{event = .KEY, node_idx = focused_idx},
						)
						break
					}
				}
			}

		case types.CharEvent:
			if focused_idx >= 0 {
				for listener in listeners {
					if cl, ok := listener.(types.ChangeListener); ok && cl.node_idx == focused_idx {
						append(
							&user_events,
							types.UserEvent{event = .CHANGE, node_idx = focused_idx},
						)
						break
					}
				}
			}

		case types.ScrollEvent:
		case types.ResizeEvent:
		}
	}

	return user_events
}
