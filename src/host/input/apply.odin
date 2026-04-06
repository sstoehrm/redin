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

			hit_focus := false
			for listener in listeners {
				switch l in listener {
				case types.FocusListener:
					if l.node_idx < len(node_rects) &&
					   rl.CheckCollisionPointRec(mouse, node_rects[l.node_idx]) {
						focused_idx = l.node_idx
						append(&applied, types.ApplyEvents(types.ApplyFocus{idx = l.node_idx}))
						hit_focus = true
					}
				case types.ClickListener:
					if l.node_idx < len(node_rects) &&
					   rl.CheckCollisionPointRec(mouse, node_rects[l.node_idx]) {
						append(&applied, types.ApplyEvents(types.ApplyActive{idx = l.node_idx}))
					}
				case types.HoverListener, types.KeyListener, types.ChangeListener:
				}
			}

			if !hit_focus {
				focused_idx = -1
			}

		case types.KeyEvent, types.CharEvent, types.ResizeEvent:
		}
	}

	return applied
}
