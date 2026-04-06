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
