package text

import "core:strings"
import "../font"
import rl "vendor:raylib"

// Style overrides for inline code spans. Resolved from the :md/code
// aspect by the caller and passed in. Zero-value fields fall back to
// hardcoded defaults compatible with the old markdown render path.
Span_Code_Style :: struct {
	font_name:        string,         // empty -> "mono"
	bg:               [3]u8,          // ignored unless bg_set
	bg_set:           bool,
	color:            [3]u8,          // ignored unless color_set
	color_set:        bool,
}

// Walk the same wrap logic as span_layout_and_draw and return the
// total laid-out height in pixels (line count × line-height). Used
// by the renderer's intrinsic-height path so span-bearing text nodes
// (markdown body / heading / list items) report a multi-line height
// instead of always one line.
//
// Mirror of span_layout_and_draw's wrap algorithm; if you change the
// wrap rules in one, change both. Allocations live in
// `context.temp_allocator`.
span_layout_measure_height :: proc(
	spans:             []Span,
	available_width:   f32,
	base_font_name:    string,
	base_font_size:    f32,
	line_height_ratio: f32,
	code_font_name_in: string = "",
) -> f32 {
	if len(spans) == 0 do return 0
	if available_width <= 0 do return 0

	lh := line_height(base_font_size, line_height_ratio)
	code_font_name := code_font_name_in
	if len(code_font_name) == 0 do code_font_name = "mono"

	cursor_x: f32 = 0
	cursor_y: f32 = 0
	first_unit_on_line := true

	font_for :: proc(style: Span_Style, base_name, code_name: string) -> rl.Font {
		switch style {
		case .Regular: return font.get(base_name, .Regular)
		case .Bold:    return font.get(base_name, .Bold)
		case .Italic:  return font.get(base_name, .Italic)
		case .Code:    return font.get(code_name, .Regular)
		}
		return font.get(base_name, .Regular)
	}

	measure :: proc(style: Span_Style, text: string,
	                base_font_name, code_font_name: string,
	                base_font_size: f32) -> f32 {
		if len(text) == 0 do return 0
		fnt := font_for(style, base_font_name, code_font_name)
		cstr := strings.clone_to_cstring(text, context.temp_allocator)
		return rl.MeasureTextEx(fnt, cstr, base_font_size, 0).x
	}

	advance :: proc(width: f32, available_width: f32, lh: f32,
	                cursor_x: ^f32, cursor_y: ^f32, first_unit_on_line: ^bool) {
		if !first_unit_on_line^ && cursor_x^ + width > available_width {
			cursor_x^ = 0
			cursor_y^ += lh
			first_unit_on_line^ = true
		}
		cursor_x^ += width
		first_unit_on_line^ = false
	}

	for span in spans {
		s := span.text
		start := 0
		i := 0
		for i < len(s) {
			ch := s[i]
			if ch == '\n' {
				if i > start {
					w := measure(span.style, s[start:i],
						base_font_name, code_font_name, base_font_size)
					advance(w, available_width, lh,
						&cursor_x, &cursor_y, &first_unit_on_line)
				}
				cursor_x = 0
				cursor_y += lh
				first_unit_on_line = true
				i += 1
				start = i
				continue
			}
			if ch == ' ' || ch == '\t' {
				if i > start {
					w := measure(span.style, s[start:i],
						base_font_name, code_font_name, base_font_size)
					advance(w, available_width, lh,
						&cursor_x, &cursor_y, &first_unit_on_line)
				}
				ws := s[i:i+1]
				i += 1
				if first_unit_on_line {
					start = i
					continue
				}
				w := measure(span.style, ws,
					base_font_name, code_font_name, base_font_size)
				advance(w, available_width, lh,
					&cursor_x, &cursor_y, &first_unit_on_line)
				start = i
				continue
			}
			i += 1
		}
		if start < len(s) {
			w := measure(span.style, s[start:],
				base_font_name, code_font_name, base_font_size)
			advance(w, available_width, lh,
				&cursor_x, &cursor_y, &first_unit_on_line)
		}
	}

	// One line was emitted at cursor_y = 0; each wrap advanced by lh.
	// Total height covers the line containing the final glyph.
	return cursor_y + lh
}

// Layout-and-draw a list of inline spans inside `rect` using mixed
// fonts derived from `base_font_name` + per-span style.
//
// `rect` is the content-area rect — padding is expected to have been
// stripped by the caller. Greedy word wrap respects whitespace
// boundaries within each span; soft line breaks ('\n' inside a span's
// text) force a wrap. Allocations live in `context.temp_allocator`.
span_layout_and_draw :: proc(
	spans:             []Span,
	rect:              rl.Rectangle,
	base_font_name:    string,
	base_font_size:    f32,
	line_height_ratio: f32,
	text_color:        rl.Color,
	code_style:        Span_Code_Style,
) {
	if len(spans) == 0 do return

	lh := line_height(base_font_size, line_height_ratio)

	code_font_name := code_style.font_name
	if len(code_font_name) == 0 do code_font_name = "mono"
	code_bg := [3]u8{60,60,70}
	if code_style.bg_set do code_bg = code_style.bg

	cursor_x: f32 = 0
	cursor_y: f32 = 0
	first_unit_on_line := true

	font_for :: proc(style: Span_Style, base_name, code_name: string) -> rl.Font {
		switch style {
		case .Regular: return font.get(base_name, .Regular)
		case .Bold:    return font.get(base_name, .Bold)
		case .Italic:  return font.get(base_name, .Italic)
		case .Code:    return font.get(code_name, .Regular)
		}
		return font.get(base_name, .Regular)
	}

	color_for :: proc(style: Span_Style, base: rl.Color, cs: Span_Code_Style) -> rl.Color {
		if style == .Code && cs.color_set {
			return rl.Color{cs.color[0], cs.color[1], cs.color[2], 255}
		}
		return base
	}

	emit :: proc(style: Span_Style, text: string,
	             rect: rl.Rectangle, lh: f32,
	             base_font_name, code_font_name: string,
	             base_font_size: f32, text_color: rl.Color,
	             code_style: Span_Code_Style, code_bg: [3]u8,
	             cursor_x: ^f32, cursor_y: ^f32, first_unit_on_line: ^bool) {
		if len(text) == 0 do return
		fnt := font_for(style, base_font_name, code_font_name)
		cstr := strings.clone_to_cstring(text, context.temp_allocator)
		size := rl.MeasureTextEx(fnt, cstr, base_font_size, 0)
		w := size.x

		if !first_unit_on_line^ && cursor_x^ + w > rect.width {
			cursor_x^ = 0
			cursor_y^ += lh
			first_unit_on_line^ = true
		}
		x := rect.x + cursor_x^
		y := rect.y + cursor_y^

		if style == .Code {
			rl.DrawRectangleRec(
				rl.Rectangle{x, y, w, lh},
				rl.Color{code_bg[0], code_bg[1], code_bg[2], 255})
		}
		col := color_for(style, text_color, code_style)
		rl.DrawTextEx(fnt, cstr, rl.Vector2{x, y}, base_font_size, 0, col)

		cursor_x^ += w
		first_unit_on_line^ = false
	}

	for span in spans {
		s := span.text
		start := 0
		i := 0
		for i < len(s) {
			ch := s[i]
			if ch == '\n' {
				if i > start {
					emit(span.style, s[start:i], rect, lh,
						base_font_name, code_font_name,
						base_font_size, text_color,
						code_style, code_bg,
						&cursor_x, &cursor_y, &first_unit_on_line)
				}
				cursor_x = 0
				cursor_y += lh
				first_unit_on_line = true
				i += 1
				start = i
				continue
			}
			if ch == ' ' || ch == '\t' {
				if i > start {
					emit(span.style, s[start:i], rect, lh,
						base_font_name, code_font_name,
						base_font_size, text_color,
						code_style, code_bg,
						&cursor_x, &cursor_y, &first_unit_on_line)
				}
				ws := s[i:i+1]
				i += 1
				if first_unit_on_line {
					start = i
					continue
				}
				emit(span.style, ws, rect, lh,
					base_font_name, code_font_name,
					base_font_size, text_color,
					code_style, code_bg,
					&cursor_x, &cursor_y, &first_unit_on_line)
				start = i
				continue
			}
			i += 1
		}
		if start < len(s) {
			emit(span.style, s[start:], rect, lh,
				base_font_name, code_font_name,
				base_font_size, text_color,
				code_style, code_bg,
				&cursor_x, &cursor_y, &first_unit_on_line)
		}
	}
}
