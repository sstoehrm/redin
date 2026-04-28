package input

import "../types"
import rl "vendor:raylib"

apply_listeners :: proc(
	listeners: [dynamic]types.Listener,
	events: [dynamic]types.InputEvent,
	node_rects: []rl.Rectangle,
) -> [dynamic]types.ApplyEvents {
	applied: [dynamic]types.ApplyEvents

	if focused_idx >= len(node_rects) {
		focused_idx = -1
	}

	for event in events {
		switch e in event {
		case types.MouseEvent:
			if e.button != .LEFT do continue
			mouse := rl.Vector2{e.x, e.y}

			// Deepest node wins (see get_user_events). Only listeners on
			// the innermost listener-bearing node under the pointer fire.
			winner := deepest_listener_idx(listeners[:], node_rects, mouse)
			new_focus := -1
			has_active := false
			if winner >= 0 {
				for listener in listeners {
					switch l in listener {
					case types.FocusListener:
						if l.node_idx == winner do new_focus = winner
					case types.ClickListener:
						if l.node_idx == winner do has_active = true
					case types.HoverListener, types.KeyListener, types.ChangeListener,
					     types.DragListener, types.DropListener, types.Text_Select_Listener,
					     types.DragOverListener:
					}
				}
			}
			focused_idx = new_focus
			if new_focus >= 0 {
				append(&applied, types.ApplyEvents(types.ApplyFocus{idx = new_focus}))
			}
			if has_active {
				append(&applied, types.ApplyEvents(types.ApplyActive{idx = winner}))
			}

		case types.KeyEvent, types.CharEvent, types.ScrollEvent, types.ResizeEvent:
		}
	}

	return applied
}
