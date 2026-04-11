package host

import "canvas"
import "core:fmt"
import "core:math"
import "core:strings"
import "font"
import "input"
import text_pkg "text"
import "types"
import rl "vendor:raylib"

// Snap to pixel grid for crisp text rendering
px :: proc(v: f32) -> f32 { return math.round(v) }

// Resolve a single ViewportValue to pixels given a window dimension.
resolve_vp :: proc(v: types.ViewportValue, window_dim: f32) -> f32 {
	switch val in v {
	case f32:
		return val
	case types.SizeValue:
		return window_dim
	case types.Fraction:
		if val.den == 0 do return 0
		return (f32(val.num) / f32(val.den)) * window_dim
	}
	return 0
}

// Layout rects populated during render, indexed by node idx.
// Used by input handling for hit testing in the next frame.
node_rects: [dynamic]rl.Rectangle

// Per-node scroll offsets for overflow containers.
scroll_offsets: map[int]f32
scroll_offsets_x: map[int]f32

SCROLL_SPEED :: 30.0 // pixels per wheel tick

apply_scroll_events :: proc(events: []types.InputEvent, nodes: []types.Node) {
	for event in events {
		if se, ok := event.(types.ScrollEvent); ok {
			pt := rl.Vector2{se.x, se.y}
			// Find the deepest scrollable node under the mouse
			best_idx := -1
			best_area: f32 = max(f32)
			for idx in 0 ..< len(nodes) {
				overflow := ""
				switch n in nodes[idx] {
				case types.NodeVbox:
					overflow = n.overflow
				case types.NodeHbox:
					overflow = n.overflow
				case types.NodeText:
					overflow = n.overflow
				case types.NodeStack, types.NodeCanvas, types.NodeInput,
					types.NodeButton, types.NodeImage,
					types.NodePopout, types.NodeModal:
				}
				if overflow != "scroll-y" do continue
				if idx >= len(node_rects) do continue
				r := node_rects[idx]
				if rl.CheckCollisionPointRec(pt, r) {
					area := r.width * r.height
					if area < best_area {
						best_area = area
						best_idx = idx
					}
				}
			}
			if best_idx >= 0 {
				offset := scroll_offsets[best_idx] if best_idx in scroll_offsets else 0
				offset -= se.delta * SCROLL_SPEED
				if offset < 0 do offset = 0
				scroll_offsets[best_idx] = offset
			}
		}
	}
}

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
		if len(n.viewport) > 0 {
			render_children_viewport(idx, n, nodes, children_list, theme)
		} else {
			render_children_stack(idx, rect, nodes, children_list, theme)
		}
	case types.NodeVbox:
		draw_box(idx, rect, n.aspect, n.layoutX, true, n.overflow, nodes, children_list, theme)
	case types.NodeHbox:
		draw_box(idx, rect, n.aspect, n.layoutX, false, n.overflow, nodes, children_list, theme)
	case types.NodeCanvas:
		// Draw aspect chrome (bg, border, radius, padding)
		content_rect := rect
		if len(n.aspect) > 0 {
			if t, ok := theme[n.aspect]; ok {
				if t.bg != {} {
					bg := rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
					if t.radius > 0 {
						roundness := f32(t.radius) / min(rect.width, rect.height) * 2
						rl.DrawRectangleRounded(rect, roundness, 6, bg)
					} else {
						rl.DrawRectangleRec(rect, bg)
					}
				}
				if t.border != {} && t.border_width > 0 {
					border := rl.Color{t.border[0], t.border[1], t.border[2], 255}
					if t.radius > 0 {
						roundness := f32(t.radius) / min(rect.width, rect.height) * 2
						rl.DrawRectangleRoundedLinesEx(
							rect,
							roundness,
							6,
							f32(t.border_width),
							border,
						)
					} else {
						rl.DrawRectangleLinesEx(rect, f32(t.border_width), border)
					}
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
		// Dispatch to canvas provider or draw placeholder
		if len(n.provider) > 0 {
			canvas.process(n.provider, content_rect)
		} else {
			rl.DrawRectangleLinesEx(content_rect, 1, rl.LIGHTGRAY)
			rl.DrawText("canvas", i32(content_rect.x) + 4, i32(content_rect.y) + 4, 16, rl.GRAY)
		}
	case types.NodeInput:
		draw_input(idx, rect, n, theme)
	case types.NodeButton:
		draw_button(rect, n, theme)
	case types.NodeText:
		draw_text(idx, rect, n, theme)
	case types.NodeImage:
		draw_themed_rect(rect, n.aspect, theme)
		rl.DrawRectangleLinesEx(rect, 1, rl.GRAY)
		rl.DrawText("image", i32(rect.x) + 4, i32(rect.y) + 4, 14, rl.GRAY)
	case types.NodePopout:
		render_children_stack(idx, rect, nodes, children_list, theme)
	case types.NodeModal:
		// Modal always covers the full screen, regardless of parent layout
		screen := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
		if idx < len(node_rects) {
			node_rects[idx] = screen
		}
		draw_themed_rect(screen, n.aspect, theme)
		render_children_stack(idx, screen, nodes, children_list, theme)
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

// stack with viewport: each child gets an absolute window-relative rect
render_children_viewport :: proc(
	idx: int,
	stack: types.NodeStack,
	nodes: []types.Node,
	children_list: []types.Children,
	theme: map[string]types.Theme,
) {
	ch := children_list[idx]
	if int(ch.length) != len(stack.viewport) {
		fmt.eprintfln("viewport: entry count %d != child count %d, skipping stack", len(stack.viewport), ch.length)
		return
	}

	win_w := f32(rl.GetScreenWidth())
	win_h := f32(rl.GetScreenHeight())

	for i in 0 ..< int(ch.length) {
		vr := stack.viewport[i]
		child_rect := rl.Rectangle {
			px(resolve_vp(vr[0], win_w)),
			px(resolve_vp(vr[1], win_h)),
			px(resolve_vp(vr[2], win_w)),
			px(resolve_vp(vr[3], win_h)),
		}
		child_idx := int(ch.value[i])
		render_node(child_idx, child_rect, nodes, children_list, theme)
	}
}

// Unified box layout for vbox (vertical=true) and hbox (vertical=false)
draw_box :: proc(
	idx: int,
	rect: rl.Rectangle,
	aspect: string,
	layoutX: types.LayoutX,
	vertical: bool,
	overflow: string,
	nodes: []types.Node,
	children_list: []types.Children,
	theme: map[string]types.Theme,
) {
	content_rect := rect

	if len(aspect) > 0 {
		bg_color: rl.Color
		has_bg := false
		pad: [4]u8

		if t, ok := theme[aspect]; ok {
			if t.bg != {} {
				bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
				has_bg = true
			}
			pad = t.padding
		}

		// Apply drag theme variants (override base)
		if input.dragging_idx == idx {
			drag_start_key := strings.concatenate({aspect, "#drag-start"}, context.temp_allocator)
			if dt, ok := theme[drag_start_key]; ok {
				if dt.bg != {} {
					bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
					has_bg = true
				}
				if dt.padding != {} do pad = dt.padding
			}
		}
		if input.drag_over_idx == idx {
			drag_key := strings.concatenate({aspect, "#drag"}, context.temp_allocator)
			if dt, ok := theme[drag_key]; ok {
				if dt.bg != {} {
					bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
					has_bg = true
				}
				if dt.padding != {} do pad = dt.padding
			}
		}

		if has_bg {
			rl.DrawRectangleRec(rect, bg_color)
		}
		if pad != {} {
			content_rect = rl.Rectangle {
				rect.x + f32(pad[3]),
				rect.y + f32(pad[0]),
				rect.width - f32(pad[1]) - f32(pad[3]),
				rect.height - f32(pad[0]) - f32(pad[2]),
			}
		}
	}

	ch := children_list[idx]
	if ch.length == 0 do return

	scrollable := overflow == "scroll-y" && vertical

	// First pass: sum fixed sizes, count fill nodes
	fixed_total: f32 = 0
	fill_count: int = 0
	for i in 0 ..< int(ch.length) {
		child_idx := int(ch.value[i])
		s :=
			vertical ? node_preferred_height(child_idx, nodes, theme) : node_preferred_width(child_idx, nodes)
		if s > 0 {
			fixed_total += s
		} else {
			fill_count += 1
		}
	}

	available := vertical ? content_rect.height : content_rect.width
	fill_size: f32 = 0

	if scrollable {
		// In scroll mode, give fill nodes a zero size (content determines layout)
		fill_size = 0
	} else if fill_count > 0 {
		remaining := available - fixed_total
		if remaining > 0 do fill_size = remaining / f32(fill_count)
	}

	// Scroll offset
	scroll_off: f32 = 0
	if scrollable {
		scroll_off = scroll_offsets[idx] if idx in scroll_offsets else 0
		// Clamp scroll to content bounds
		total_content := fixed_total
		max_scroll := total_content - content_rect.height
		if max_scroll < 0 do max_scroll = 0
		if scroll_off > max_scroll do scroll_off = max_scroll
		if scroll_off < 0 do scroll_off = 0
		scroll_offsets[idx] = scroll_off

		rl.BeginScissorMode(
			i32(content_rect.x), i32(content_rect.y),
			i32(content_rect.width), i32(content_rect.height),
		)
	}

	// Second pass: layout and render
	center := layoutX == .CENTER
	pos := (vertical ? content_rect.y : content_rect.x) - scroll_off

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

	if scrollable {
		rl.EndScissorMode()

		// Draw scroll bar if content overflows
		total_content := fixed_total
		if total_content > content_rect.height {
			bar_w: f32 = 4
			bar_x := content_rect.x + content_rect.width - bar_w
			visible_ratio := content_rect.height / total_content
			bar_h := max(content_rect.height * visible_ratio, 20)
			max_scroll := total_content - content_rect.height
			scroll_ratio := scroll_off / max_scroll if max_scroll > 0 else 0
			bar_y := content_rect.y + scroll_ratio * (content_rect.height - bar_h)
			rl.DrawRectangleRounded(
				{bar_x, bar_y, bar_w, bar_h},
				1, 4,
				rl.Color{200, 200, 200, 120},
			)
		}
	}
}

// Helper: extract f32 from union{SizeValue, f32}
size_f32 :: proc(size: union {
		types.SizeValue,
		f32,
	}) -> f32 {
	if v, ok := size.(f32); ok do return v
	return 0
}

// Helper: extract f32 from union{SizeValue, f16}
size_f16 :: proc(size: union {
		types.SizeValue,
		f16,
	}) -> f32 {
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
	case types.NodeCanvas:
		return size_f16(n.width)
	case types.NodeStack, types.NodeModal:
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
				return f32(t.font_size) + 4
			}
		}
		return 22
	case types.NodeImage:
		return size_f32(n.height)
	case types.NodeVbox:
		return size_f16(n.height)
	case types.NodeHbox:
		return size_f32(n.height)
	case types.NodePopout:
		return size_f32(n.height)
	case types.NodeCanvas:
		return size_f16(n.height)
	case types.NodeStack, types.NodeModal:
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
	placeholder_color := rl.Color{128, 128, 128, 128}
	selection_color := rl.Color{51, 153, 255, 100}
	font_size: f32 = 14
	padding_l: f32 = 4
	padding_r: f32 = 4
	padding_t: f32 = 4
	border_width: f32 = 1
	font_name := "sans"
	font_weight: u8 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.border != {} do border_color = rl.Color{t.border[0], t.border[1], t.border[2], 255}
			if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if t.font_size > 0 do font_size = f32(t.font_size)
			if t.border_width > 0 do border_width = f32(t.border_width)
			if t.padding[3] > 0 do padding_l = f32(t.padding[3])
			if t.padding[1] > 0 do padding_r = f32(t.padding[1])
			if t.padding[0] > 0 do padding_t = f32(t.padding[0])
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
		}
		if is_focused {
			focus_key := strings.concatenate({n.aspect, "#focus"}, context.temp_allocator)
			if ft, ok := theme[focus_key]; ok {
				if ft.border != {} do border_color = rl.Color{ft.border[0], ft.border[1], ft.border[2], 255}
			}
		}
	}

	// Draw background and border
	if bg_color.a > 0 do rl.DrawRectangleRec(rect, bg_color)
	rl.DrawRectangleLinesEx(rect, border_width, border_color)

	// Content area
	content_x := rect.x + padding_l
	content_y := rect.y + padding_t
	content_w := rect.width - padding_l - padding_r
	content_h := rect.height - padding_t * 2

	f := font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
	spacing: f32 = 0
	lh := text_pkg.line_height(font_size)

	// Determine text to display
	display_text: string
	show_placeholder := false
	if is_focused && input.state.active {
		display_text = input.get_text()
	} else if len(n.value) > 0 {
		display_text = n.value
	} else if len(n.placeholder) > 0 {
		display_text = n.placeholder
		show_placeholder = true
	}

	// Compute lines with word-wrap
	lines := text_pkg.compute_lines(display_text, f, font_size, spacing, content_w)
	defer delete(lines)

	// Vertical scroll management — keep cursor visible
	scroll_y: f32 = 0
	if is_focused && input.state.active {
		scroll_y = input.state.scroll_offset_y
		cursor_line, _ := text_pkg.cursor_to_line(lines[:], input.state.cursor)
		cursor_y_top := f32(cursor_line) * lh
		cursor_y_bot := cursor_y_top + lh

		if cursor_y_top < scroll_y {
			scroll_y = cursor_y_top
		} else if cursor_y_bot > scroll_y + content_h {
			scroll_y = cursor_y_bot - content_h
		}
		if scroll_y < 0 do scroll_y = 0
		input.state.scroll_offset_y = scroll_y
	}

	// Scissor clip to content area
	rl.BeginScissorMode(i32(content_x), i32(content_y), i32(content_w), i32(content_h))

	// Draw selection highlight (behind text)
	if is_focused && input.state.active && input.has_selection() {
		lo, hi := input.selection_range()
		for line, i in lines {
			ly := content_y + f32(i) * lh - scroll_y
			if ly + lh < content_y || ly > content_y + content_h do continue

			sel_start := max(lo, line.start)
			sel_end := min(hi, line.end)
			if sel_start >= sel_end do continue

			x0 := text_pkg.measure_range(display_text, line.start, sel_start, f, font_size, spacing)
			x1 := text_pkg.measure_range(display_text, line.start, sel_end, f, font_size, spacing)
			sel_rect := rl.Rectangle{content_x + x0, ly, x1 - x0, lh}
			rl.DrawRectangleRec(sel_rect, selection_color)
		}
	}

	// Draw text lines
	color := show_placeholder ? placeholder_color : text_color
	for line, i in lines {
		ly := content_y + f32(i) * lh - scroll_y
		if ly + lh < content_y do continue
		if ly > content_y + content_h do break

		if line.start < line.end {
			cstr := strings.clone_to_cstring(display_text[line.start:line.end], context.temp_allocator)
			rl.DrawTextEx(f, cstr, {px(content_x), px(ly)}, font_size, spacing, color)
		}
	}

	// Draw cursor with wipe animation
	if is_focused && input.state.active {
		cursor_line, _ := text_pkg.cursor_to_line(lines[:], input.state.cursor)
		cur_line := lines[cursor_line]
		cursor_x_offset := text_pkg.measure_range(
			display_text, cur_line.start, input.state.cursor, f, font_size, spacing,
		)
		cursor_x := content_x + cursor_x_offset
		cursor_y := content_y + f32(cursor_line) * lh - scroll_y

		cycle := f32(rl.GetTime()) * 0.4
		phase := cycle - f32(i32(cycle))
		wave: f32
		if phase < 0.5 {
			wave = phase * 2
		} else {
			wave = (1 - phase) * 2
		}

		CURSOR_SLICES :: 8
		slice_h := lh / f32(CURSOR_SLICES)
		for s in 0 ..< i32(CURSOR_SLICES) {
			norm := 1.0 - (f32(s) + 0.5) / f32(CURSOR_SLICES)
			alpha_norm := clamp(wave * 2.0 - norm, 0, 1)
			alpha := u8(alpha_norm * f32(text_color.a))
			slice_y := cursor_y + f32(s) * slice_h
			c := rl.Color{text_color.r, text_color.g, text_color.b, alpha}
			rl.DrawLineEx(
				rl.Vector2{cursor_x, slice_y},
				rl.Vector2{cursor_x, slice_y + slice_h},
				1.5,
				c,
			)
		}
	}

	rl.EndScissorMode()
}

draw_button :: proc(rect: rl.Rectangle, n: types.NodeButton, theme: map[string]types.Theme) {
	bg_color := rl.LIGHTGRAY
	text_color := rl.BLACK
	radius: f32 = 0
	font_size: f32 = 18
	font_name := "sans"
	font_weight: u8 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if t.radius > 0 do radius = f32(t.radius)
			if t.font_size > 0 do font_size = f32(t.font_size)
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
		}
	}

	if radius > 0 {
		roundness := radius / min(rect.width, rect.height) * 2
		rl.DrawRectangleRounded(rect, roundness, 6, bg_color)
	} else {
		rl.DrawRectangleRec(rect, bg_color)
	}

	if len(n.label) > 0 {
		f := font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
		spacing: f32 = 0
		text := strings.clone_to_cstring(n.label, context.temp_allocator)
		size := rl.MeasureTextEx(f, text, font_size, spacing)
		tx := px(rect.x + (rect.width - size.x) / 2)
		ty := px(rect.y + (rect.height - size.y) / 2)
		rl.DrawTextEx(f, text, {tx, ty}, font_size, spacing, text_color)
	}
}

draw_text :: proc(idx: int, rect: rl.Rectangle, n: types.NodeText, theme: map[string]types.Theme) {
	if len(n.content) == 0 do return

	font_size: f32 = 18
	text_color := rl.BLACK
	font_name := "sans"
	font_weight: u8 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do font_size = f32(t.font_size)
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
		}
	}

	f := font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
	spacing: f32 = 0
	lh := text_pkg.line_height(font_size)

	// Compute lines: wrap if not scroll-x
	max_width: f32 = 0
	if n.overflow != "scroll-x" {
		max_width = rect.width
	}
	lines := text_pkg.compute_lines(n.content, f, font_size, spacing, max_width)
	defer delete(lines)

	scrollable_y := n.overflow == "scroll-y"
	scrollable_x := n.overflow == "scroll-x"

	scroll_y: f32 = 0
	scroll_x: f32 = 0
	if scrollable_y {
		scroll_y = scroll_offsets[idx] if idx in scroll_offsets else 0
		total_h := f32(len(lines)) * lh
		max_scroll := total_h - rect.height
		if max_scroll < 0 do max_scroll = 0
		if scroll_y > max_scroll do scroll_y = max_scroll
		if scroll_y < 0 do scroll_y = 0
		scroll_offsets[idx] = scroll_y
	}
	if scrollable_x {
		scroll_x = scroll_offsets_x[idx] if idx in scroll_offsets_x else 0
	}

	// Clip when content may overflow the rect
	needs_clip := scrollable_y || scrollable_x || (len(lines) > 1 && f32(len(lines)) * lh > rect.height)
	if needs_clip {
		rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
	}

	for line, i in lines {
		ly := rect.y + f32(i) * lh - scroll_y
		if ly + lh < rect.y do continue
		if ly > rect.y + rect.height do break

		if line.start < line.end {
			cstr := strings.clone_to_cstring(n.content[line.start:line.end], context.temp_allocator)
			rl.DrawTextEx(f, cstr, {px(rect.x - scroll_x), px(ly)}, font_size, spacing, text_color)
		}
	}

	if needs_clip {
		rl.EndScissorMode()
	}
}
