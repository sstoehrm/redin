package input

import "../types"
import rl "vendor:raylib"

DRAG_THRESHOLD :: 4.0

Drag_Source :: struct {
	group:       string,
	event:       string,
	context_ref: i32,
}

dragging_idx:   int = -1
drag_over_idx:  int = -1
drag_pending:   bool = false
drag_start_pos: rl.Vector2
drag_source:    Drag_Source

process_drag :: proc(
	input_events: []types.InputEvent,
	listeners: []types.Listener,
	nodes: []types.Node,
	node_rects: []rl.Rectangle,
) -> [dynamic]types.Dispatch_Event {
	dispatch: [dynamic]types.Dispatch_Event
	mouse := rl.GetMousePosition()

	// Phase 1: Check for new drag initiation (mouse press on a DragListener)
	if !drag_pending && dragging_idx == -1 {
		for event in input_events {
			me, is_mouse := event.(types.MouseEvent)
			if !is_mouse || me.button != .LEFT do continue
			pt := rl.Vector2{me.x, me.y}

			for listener in listeners {
				dl, ok := listener.(types.DragListener)
				if !ok do continue
				if dl.node_idx >= len(node_rects) do continue
				if !rl.CheckCollisionPointRec(pt, node_rects[dl.node_idx]) do continue

				drag_pending = true
				drag_start_pos = pt

				switch n in nodes[dl.node_idx] {
				case types.NodeVbox:
					drag_source = {n.draggable_group, n.draggable_event, n.draggable_ctx}
					dragging_idx = dl.node_idx
				case types.NodeHbox:
					drag_source = {n.draggable_group, n.draggable_event, n.draggable_ctx}
					dragging_idx = dl.node_idx
				case types.NodeStack, types.NodeCanvas, types.NodeInput,
					types.NodeButton, types.NodeText, types.NodeImage,
					types.NodePopout, types.NodeModal:
				}
				break
			}
		}
	}

	// Phase 2: Pending -> check threshold or cancel
	if drag_pending && dragging_idx >= 0 {
		if rl.IsMouseButtonDown(.LEFT) {
			dx := mouse.x - drag_start_pos.x
			dy := mouse.y - drag_start_pos.y
			dist_sq := dx * dx + dy * dy
			if dist_sq >= DRAG_THRESHOLD * DRAG_THRESHOLD {
				drag_pending = false
				if len(drag_source.event) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drag_Event{
						event_name  = drag_source.event,
						context_ref = drag_source.context_ref,
					}))
				}
			}
		} else {
			drag_pending = false
			dragging_idx = -1
			drag_over_idx = -1
		}
	}

	// Phase 3: Active dragging - hit-test drop targets each frame
	if !drag_pending && dragging_idx >= 0 {
		if rl.IsMouseButtonDown(.LEFT) {
			drag_over_idx = -1
			for listener in listeners {
				dl, ok := listener.(types.DropListener)
				if !ok do continue
				if dl.group != drag_source.group do continue
				if dl.node_idx >= len(node_rects) do continue
				if rl.CheckCollisionPointRec(mouse, node_rects[dl.node_idx]) {
					drag_over_idx = dl.node_idx
					break
				}
			}
		} else {
			if drag_over_idx >= 0 {
				drop_event := ""
				drop_ctx: i32 = 0
				switch n in nodes[drag_over_idx] {
				case types.NodeVbox:
					drop_event = n.dropable_event
					drop_ctx = n.dropable_ctx
				case types.NodeHbox:
					drop_event = n.dropable_event
					drop_ctx = n.dropable_ctx
				case types.NodeStack, types.NodeCanvas, types.NodeInput,
					types.NodeButton, types.NodeText, types.NodeImage,
					types.NodePopout, types.NodeModal:
				}

				if len(drop_event) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drop_Event{
						event_name = drop_event,
						from_ref   = drag_source.context_ref,
						to_ref     = drop_ctx,
					}))
				}
			}

			dragging_idx = -1
			drag_over_idx = -1
			drag_pending = false
			drag_source = {}
		}
	}

	return dispatch
}

is_dragging :: proc() -> bool {
	return drag_pending || dragging_idx >= 0
}
