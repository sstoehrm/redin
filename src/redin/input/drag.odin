package input

import "core:strings"
import "../types"
import rl "vendor:raylib"

// Heap-clone a borrowed []string into an owned slice. Used to detach
// captured drag state from the per-frame listener tags (which are freed
// across re-flattens via clear_node_strings).
clone_string_slice :: proc(src: []string) -> []string {
	if len(src) == 0 do return nil
	out := make([]string, len(src))
	for s, i in src do out[i] = strings.clone(s)
	return out
}

free_string_slice :: proc(s: []string) {
	for v in s do delete(v)
	if s != nil do delete(s)
}

// Heap-clone an Animate_Decoration so the captured drag state owns its
// `provider` string independent of node lifetime. Pass-through nil.
clone_animate :: proc(src: Maybe(types.Animate_Decoration)) -> Maybe(types.Animate_Decoration) {
	dec, ok := src.?
	if !ok do return nil
	out := dec
	if len(dec.provider) > 0 do out.provider = strings.clone(dec.provider)
	return out
}

// Free an Animate_Decoration's owned provider string, if any.
free_animate :: proc(m: Maybe(types.Animate_Decoration)) {
	if dec, ok := m.?; ok && len(dec.provider) > 0 do delete(dec.provider)
}

// Release every heap-owned field of a Drag_Captured. Safe to call once per
// transition out of Pending or Active back to Idle.
free_captured :: proc(c: Drag_Captured) {
	free_string_slice(c.src_tags)
	if len(c.src_event) > 0 do delete(c.src_event)
	if len(c.src_aspect) > 0 do delete(c.src_aspect)
	free_animate(c.src_animate)
}

// ---- v2 state machine ----

Drag_Captured :: struct {
	src_idx:     int,
	start_pos:   rl.Vector2,
	src_tags:    []string,                       // owned (heap-cloned at capture)
	src_event:   string,                         // owned (heap-cloned at capture)
	src_mode:    types.Drag_Mode,
	src_aspect:  string,                         // owned
	src_animate: Maybe(types.Animate_Decoration),// owned (provider string inside)
	src_ctx_ref: i32,
}

Drag_Idle    :: struct {}

Drag_Pending :: struct {
	using captured: Drag_Captured,
}

Drag_Active :: struct {
	using captured: Drag_Captured,
	over_zone_idx:  int,        // -1 if no zone hovered
	over_drop_idx:  int,        // -1 if no drop cell hovered
}

Drag_State :: union { Drag_Idle, Drag_Pending, Drag_Active }

drag: Drag_State = Drag_Idle{}

// True iff src and target share at least one tag.
drag_matches :: proc(src, target: []string) -> bool {
	for s in src do for t in target do if s == t do return true
	return false
}

// Deepest matching DropListener under `pt` whose tags overlap `src_tags`.
// Deepest = highest node_idx (DFS-ordered nodes guarantee descendants > ancestors).
deepest_dropable_match :: proc(
	src_tags: []string,
	pt: rl.Vector2,
	listeners: []types.Listener,
	node_rects: []rl.Rectangle,
) -> int {
	best := -1
	for listener in listeners {
		l, ok := listener.(types.DropListener)
		if !ok do continue
		if !drag_matches(src_tags, l.tags) do continue
		if l.node_idx < 0 || l.node_idx >= len(node_rects) do continue
		if l.node_idx <= best do continue
		if !rl.CheckCollisionPointRec(pt, node_rects[l.node_idx]) do continue
		best = l.node_idx
	}
	return best
}

// Deepest matching DragOverListener under `pt`.
deepest_drag_over_match :: proc(
	src_tags: []string,
	pt: rl.Vector2,
	listeners: []types.Listener,
	node_rects: []rl.Rectangle,
) -> int {
	best := -1
	for listener in listeners {
		l, ok := listener.(types.DragOverListener)
		if !ok do continue
		if !drag_matches(src_tags, l.tags) do continue
		if l.node_idx < 0 || l.node_idx >= len(node_rects) do continue
		if l.node_idx <= best do continue
		if !rl.CheckCollisionPointRec(pt, node_rects[l.node_idx]) do continue
		best = l.node_idx
	}
	return best
}

DRAG_THRESHOLD :: 4.0

process_drag :: proc(
	input_events: []types.InputEvent,
	listeners: []types.Listener,
	nodes: []types.Node,
	node_rects: []rl.Rectangle,
) -> [dynamic]types.Dispatch_Event {
	dispatch: [dynamic]types.Dispatch_Event
	mouse := rl.GetMousePosition()

	// Escape cancels any in-flight drag (Pending or Active). When cancelling
	// from Active with an entered :drag-over zone, fire a final :phase :leave
	// so the app can tear down zone-level state. No drop event fires.
	esc_pressed := false
	for event in input_events {
		if ke, is_key := event.(types.KeyEvent); is_key && ke.key == .ESCAPE {
			esc_pressed = true
			break
		}
	}
	if esc_pressed {
		switch &s in drag {
		case Drag_Idle:
			// Nothing to cancel.
		case Drag_Pending:
			free_captured(s.captured)
			drag = Drag_Idle{}
		case Drag_Active:
			if s.over_zone_idx >= 0 && s.over_zone_idx < len(nodes) {
				if ev := node_over_event(nodes[s.over_zone_idx]); len(ev) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drag_Over_Event{
						event_name = ev,
						phase      = .Leave,
					}))
				}
			}
			free_captured(s.captured)
			drag = Drag_Idle{}
		}
		return dispatch
	}

	switch &s in drag {
	case Drag_Idle:
		// Mouse-down on a DragListener → Pending.
		for event in input_events {
			me, is_mouse := event.(types.MouseEvent)
			if !is_mouse || me.button != .LEFT do continue
			pt := rl.Vector2{me.x, me.y}

			winner := deepest_listener_idx(listeners, node_rects, pt)
			if winner < 0 do continue

			// Confirm the deepest listener winner is actually a DragListener.
			has_drag := false
			tags: []string
			for listener in listeners {
				dl, ok := listener.(types.DragListener)
				if !ok do continue
				if dl.node_idx == winner {
					has_drag = true
					tags = dl.tags
					break
				}
			}
			if !has_drag do continue

			// Read drag attrs from the source node (vbox / hbox only).
			cap := Drag_Captured{
				src_idx   = winner,
				start_pos = pt,
				src_tags  = clone_string_slice(tags),
			}
			switch n in nodes[winner] {
			case types.NodeVbox:
				if d, ok := n.draggable.?; ok {
					cap.src_event   = strings.clone(d.event)
					cap.src_mode    = d.mode
					cap.src_aspect  = strings.clone(d.aspect)
					cap.src_animate = clone_animate(d.animate)
					cap.src_ctx_ref = d.ctx
				}
			case types.NodeHbox:
				if d, ok := n.draggable.?; ok {
					cap.src_event   = strings.clone(d.event)
					cap.src_mode    = d.mode
					cap.src_aspect  = strings.clone(d.aspect)
					cap.src_animate = clone_animate(d.animate)
					cap.src_ctx_ref = d.ctx
				}
			case types.NodeStack, types.NodeCanvas, types.NodeInput,
				 types.NodeButton, types.NodeText, types.NodeImage,
				 types.NodePopout, types.NodeModal:
			}
			if len(cap.src_event) == 0 do continue

			drag = Drag_Pending{captured = cap}
			break
		}

	case Drag_Pending:
		if rl.IsMouseButtonDown(.LEFT) {
			dx := mouse.x - s.start_pos.x
			dy := mouse.y - s.start_pos.y
			if dx*dx + dy*dy >= DRAG_THRESHOLD * DRAG_THRESHOLD {
				if len(s.src_event) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drag_Event{
						event_name  = s.src_event,
						context_ref = s.src_ctx_ref,
					}))
				}
				drag = Drag_Active{
					captured      = s.captured,
					over_zone_idx = -1,
					over_drop_idx = -1,
				}
			}
		} else {
			free_captured(s.captured)
			drag = Drag_Idle{}
		}

	case Drag_Active:
		// Re-flatten safety: if the source idx no longer points at a draggable
		// with our tags, cancel.
		if s.src_idx < 0 || s.src_idx >= len(nodes) {
			free_captured(s.captured)
			drag = Drag_Idle{}
			return dispatch
		}
		// Stale zone/drop indices from a previous frame's layout — clear before use.
		if s.over_zone_idx >= len(nodes) do s.over_zone_idx = -1
		if s.over_drop_idx >= len(nodes) do s.over_drop_idx = -1

		// Hit-test compatible drop targets and zones.
		new_zone := deepest_drag_over_match(s.src_tags, mouse, listeners, node_rects)
		new_drop := deepest_dropable_match (s.src_tags, mouse, listeners, node_rects)

		// Enter/leave on zone transitions.
		if new_zone != s.over_zone_idx {
			if s.over_zone_idx >= 0 {
				if ev := node_over_event(nodes[s.over_zone_idx]); len(ev) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drag_Over_Event{
						event_name = ev,
						phase      = .Leave,
					}))
				}
			}
			if new_zone >= 0 {
				if ev := node_over_event(nodes[new_zone]); len(ev) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drag_Over_Event{
						event_name = ev,
						phase      = .Enter,
					}))
				}
			}
			s.over_zone_idx = new_zone
		}
		s.over_drop_idx = new_drop

		if !rl.IsMouseButtonDown(.LEFT) {
			// Drop dispatch.
			if new_drop >= 0 {
				drop_event := ""
				drop_ctx: i32 = 0
				switch n in nodes[new_drop] {
				case types.NodeVbox:
					if d, ok := n.dropable.?; ok {
						drop_event = d.event
						drop_ctx   = d.ctx
					}
				case types.NodeHbox:
					if d, ok := n.dropable.?; ok {
						drop_event = d.event
						drop_ctx   = d.ctx
					}
				case types.NodeStack, types.NodeCanvas, types.NodeInput,
					 types.NodeButton, types.NodeText, types.NodeImage,
					 types.NodePopout, types.NodeModal:
				}
				if len(drop_event) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drop_Event{
						event_name = drop_event,
						from_ref   = s.src_ctx_ref,
						to_ref     = drop_ctx,
					}))
				}
			}

			// Final :leave on the active zone.
			if s.over_zone_idx >= 0 {
				if ev := node_over_event(nodes[s.over_zone_idx]); len(ev) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drag_Over_Event{
						event_name = ev,
						phase      = .Leave,
					}))
				}
			}

			free_captured(s.captured)
			drag = Drag_Idle{}
		}
	}

	return dispatch
}

// Helper — extract :drag-over event name from a node, "" if not a container or no event.
node_over_event :: proc(n: types.Node) -> string {
	switch v in n {
	case types.NodeVbox:
		if d, ok := v.drag_over.?; ok do return d.event
	case types.NodeHbox:
		if d, ok := v.drag_over.?; ok do return d.event
	case types.NodeStack, types.NodeCanvas, types.NodeInput,
		 types.NodeButton, types.NodeText, types.NodeImage,
		 types.NodePopout, types.NodeModal:
	}
	return ""
}

is_dragging :: proc() -> bool {
	switch _ in drag {
	case Drag_Pending, Drag_Active: return true
	case Drag_Idle:                 return false
	}
	return false
}
