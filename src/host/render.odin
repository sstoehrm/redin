package host

import "core:strings"
import "input"
import "types"
import rl "vendor:raylib"

// Layout rects populated during render, indexed by node idx.
// Used by input handling for hit testing in the next frame.
node_rects: [dynamic]rl.Rectangle

render_tree :: proc(
	theme: map[string]types.Theme,
	nodes: []types.Node,
	children_list: []types.Children,
) {
	if len(nodes) == 0 do return

	// Reset rects array to match current tree size
	resize(&node_rects, len(nodes))
	for &r in node_rects {
		r = {}
	}

	screen := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	render_node(0, screen, nodes, children_list, theme)
}

render_node :: proc(
	idx: int,
	rect: rl.Rectangle,
	nodes: []types.Node,
	children_list: []types.Children,
	theme: map[string]types.Theme,
) {
	if idx < 0 || idx >= len(nodes) do return

	// Store layout rect for hit testing
	if idx < len(node_rects) {
		node_rects[idx] = rect
	}

	switch n in nodes[idx] {
	case types.NodeStack:
		render_children_stack(idx, rect, nodes, children_list, theme)
	case types.NodeVbox:
		draw_box(idx, rect, n.aspect, n.layoutX, true, nodes, children_list, theme)
	case types.NodeHbox:
		draw_box(idx, rect, n.aspect, n.layoutX, false, nodes, children_list, theme)
	case types.NodeCanvas:
		rl.DrawRectangleLinesEx(rect, 1, rl.LIGHTGRAY)
		rl.DrawText("canvas", i32(rect.x) + 4, i32(rect.y) + 4, 16, rl.GRAY)
	case types.NodeInput:
		draw_input(idx, rect, n, theme)
	case types.NodeButton:
		draw_button(rect, n, theme)
	case types.NodeText:
		draw_text(rect, n, theme)
	case types.NodeImage:
		draw_themed_rect(rect, n.aspect, theme)
		rl.DrawRectangleLinesEx(rect, 1, rl.GRAY)
		rl.DrawText("image", i32(rect.x) + 4, i32(rect.y) + 4, 14, rl.GRAY)
	case types.NodePopout:
		render_children_stack(idx, rect, nodes, children_list, theme)
	case types.NodeModal:
		draw_themed_rect(rect, n.aspect, theme)
		render_children_stack(idx, rect, nodes, children_list, theme)
	}
}

// stack: each child gets the full parent rect (overlapping)
render_children_stack :: proc(
	idx: int,
	rect: rl.Rectangle,
	nodes: []types.Node,
	children_list: []types.Children,
	theme: map[string]types.Theme,
) {
	ch := children_list[idx]
	for i in 0 ..< int(ch.length) {
		child_idx := int(ch.value[i])
		render_node(child_idx, rect, nodes, children_list, theme)
	}
}

// Unified box layout for vbox (vertical=true) and hbox (vertical=false)
draw_box :: proc(
	idx: int,
	rect: rl.Rectangle,
	aspect: string,
	layoutX: types.LayoutX,
	vertical: bool,
	nodes: []types.Node,
	children_list: []types.Children,
	theme: map[string]types.Theme,
) {
	content_rect := rect

	if len(aspect) > 0 {
		if t, ok := theme[aspect]; ok {
			if t.bg != {} {
				bg := rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
				rl.DrawRectangleRec(rect, bg)
			}
			if t.padding != {} {
				content_rect = rl.Rectangle {
					rect.x + f32(t.padding[3]),
					rect.y + f32(t.padding[0]),
					rect.width - f32(t.padding[1]) - f32(t.padding[3]),
					rect.height - f32(t.padding[0]) - f32(t.padding[2]),
				}
			}
		}
	}

	ch := children_list[idx]
	if ch.length == 0 do return

	// First pass: sum fixed sizes, count fill nodes
	fixed_total: f32 = 0
	fill_count: int = 0
	for i in 0 ..< int(ch.length) {
		child_idx := int(ch.value[i])
		s := vertical ? node_preferred_height(child_idx, nodes, theme) : node_preferred_width(child_idx, nodes)
		if s > 0 {
			fixed_total += s
		} else {
			fill_count += 1
		}
	}

	available := vertical ? content_rect.height : content_rect.width
	fill_size: f32 = 0
	if fill_count > 0 {
		remaining := available - fixed_total
		if remaining > 0 do fill_size = remaining / f32(fill_count)
	}

	// Second pass: layout and render
	center := layoutX == .CENTER
	pos := vertical ? content_rect.y : content_rect.x

	for i in 0 ..< int(ch.length) {
		child_idx := int(ch.value[i])

		child_rect: rl.Rectangle
		if vertical {
			h := node_preferred_height(child_idx, nodes, theme)
			if h <= 0 do h = fill_size
			child_x := content_rect.x
			child_w := content_rect.width
			if center {
				w := node_preferred_width(child_idx, nodes)
				if w > 0 {
					child_x = content_rect.x + (content_rect.width - w) / 2
					child_w = w
				}
			}
			child_rect = rl.Rectangle{child_x, pos, child_w, h}
			pos += h
		} else {
			w := node_preferred_width(child_idx, nodes)
			if w <= 0 do w = fill_size
			child_rect = rl.Rectangle{pos, content_rect.y, w, content_rect.height}
			pos += w
		}

		render_node(child_idx, child_rect, nodes, children_list, theme)
	}
}

// Helper: extract f32 from union{SizeValue, f32}
size_f32 :: proc(size: union {types.SizeValue, f32}) -> f32 {
	if v, ok := size.(f32); ok do return v
	return 0
}

// Helper: extract f32 from union{SizeValue, f16}
size_f16 :: proc(size: union {types.SizeValue, f16}) -> f32 {
	if v, ok := size.(f16); ok do return f32(v)
	return 0
}

node_preferred_width :: proc(idx: int, nodes: []types.Node) -> f32 {
	switch n in nodes[idx] {
	case types.NodeInput:
		return size_f32(n.width)
	case types.NodeButton:
		return size_f32(n.width)
	case types.NodeText:
		return size_f32(n.width)
	case types.NodeImage:
		return size_f32(n.width)
	case types.NodeVbox:
		return size_f16(n.width)
	case types.NodeHbox:
		return size_f32(n.width)
	case types.NodePopout:
		return size_f32(n.width)
	case types.NodeStack, types.NodeCanvas, types.NodeModal:
		return 0
	}
	return 0
}

node_preferred_height :: proc(
	idx: int,
	nodes: []types.Node,
	theme: map[string]types.Theme,
) -> f32 {
	switch n in nodes[idx] {
	case types.NodeInput:
		return size_f32(n.height)
	case types.NodeButton:
		return size_f32(n.height)
	case types.NodeText:
		h := size_f32(n.height)
		if h > 0 do return h
		if len(n.aspect) > 0 {
			if t, ok := theme[n.aspect]; ok && t.font_size > 0 {
				return f32(t.font_size) + 6
			}
		}
		return 24
	case types.NodeImage:
		return size_f32(n.height)
	case types.NodeVbox:
		return size_f16(n.height)
	case types.NodeHbox:
		return size_f32(n.height)
	case types.NodePopout:
		return size_f32(n.height)
	case types.NodeStack, types.NodeCanvas, types.NodeModal:
		return 0
	}
	return 0
}

draw_themed_rect :: proc(rect: rl.Rectangle, aspect: string, theme: map[string]types.Theme) {
	if len(aspect) > 0 {
		if t, ok := theme[aspect]; ok && t.bg != {} {
			bg := rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			rl.DrawRectangleRec(rect, bg)
		}
	}
}

draw_input :: proc(
	idx: int,
	rect: rl.Rectangle,
	n: types.NodeInput,
	theme: map[string]types.Theme,
) {
	is_focused := input.focused_idx == idx

	border_color := rl.DARKGRAY
	bg_color := rl.Color{0, 0, 0, 0}
	text_color := rl.WHITE
	font_size: i32 = 14
	padding_l: f32 = 4
	border_width: f32 = 1

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.border != {} do border_color = rl.Color{t.border[0], t.border[1], t.border[2], 255}
			if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if t.font_size > 0 do font_size = i32(t.font_size)
			if t.border_width > 0 do border_width = f32(t.border_width)
			if t.padding[3] > 0 do padding_l = f32(t.padding[3])
		}
		if is_focused {
			focus_key := strings.concatenate({n.aspect, "#focus"}, context.temp_allocator)
			if ft, ok := theme[focus_key]; ok {
				if ft.border != {} do border_color = rl.Color{ft.border[0], ft.border[1], ft.border[2], 255}
			}
		}
	}

	if bg_color.a > 0 do rl.DrawRectangleRec(rect, bg_color)
	rl.DrawRectangleLinesEx(rect, border_width, border_color)

	if is_focused {
		blink := int(rl.GetTime() * 2) % 2 == 0
		if blink {
			cursor_x := rect.x + padding_l
			cursor_y := rect.y + (rect.height - f32(font_size)) / 2
			rl.DrawLineEx(
				rl.Vector2{cursor_x, cursor_y},
				rl.Vector2{cursor_x, cursor_y + f32(font_size)},
				1.5,
				text_color,
			)
		}
	}
}

draw_button :: proc(rect: rl.Rectangle, n: types.NodeButton, theme: map[string]types.Theme) {
	bg_color := rl.LIGHTGRAY
	text_color := rl.BLACK
	radius: f32 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if t.radius > 0 do radius = f32(t.radius)
		}
	}

	if radius > 0 {
		roundness := radius / min(rect.width, rect.height) * 2
		rl.DrawRectangleRounded(rect, roundness, 6, bg_color)
	} else {
		rl.DrawRectangleRec(rect, bg_color)
	}

	if len(n.label) > 0 {
		font_size: i32 = 18
		text := strings.clone_to_cstring(n.label, context.temp_allocator)
		tw := rl.MeasureText(text, font_size)
		tx := i32(rect.x) + (i32(rect.width) - tw) / 2
		ty := i32(rect.y) + (i32(rect.height) - font_size) / 2
		rl.DrawText(text, tx, ty, font_size, text_color)
	}
}

draw_text :: proc(rect: rl.Rectangle, n: types.NodeText, theme: map[string]types.Theme) {
	if len(n.content) == 0 do return

	font_size: i32 = 18
	text_color := rl.BLACK

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do font_size = i32(t.font_size)
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
		}
	}

	text := strings.clone_to_cstring(n.content, context.temp_allocator)
	rl.DrawText(text, i32(rect.x), i32(rect.y) + 2, font_size, text_color)
}
