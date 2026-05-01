package markdown

import "core:strings"
import "../font"
import text_pkg "../text"
import rl "vendor:raylib"

Span_Box :: struct {
	style:  Span_Style,
	text:   string,
	x:      f32,
	y:      f32,
	width:  f32,
	height: f32,
}

Laid_Block :: struct {
	spans:        []Span_Box,
	total_height: f32,
}

font_for :: proc(style: Span_Style, base_name: string) -> rl.Font {
	switch style {
	case .Regular: return font.get(base_name, .Regular)
	case .Bold:    return font.get(base_name, .Bold)
	case .Italic:  return font.get(base_name, .Italic)
	case .Code:    return font.get("mono", .Regular)
	}
	return font.get(base_name, .Regular)
}

// Word-wrap a list of blocks. Each "wrap unit" (a whitespace-bounded token,
// or a literal \n which is a forced break) becomes one Span_Box. Greedy
// line-fill. Allocations come from the supplied allocator.
layout :: proc(
	blocks: []Block,
	base_font_name: string,
	base_font_size: f32,
	line_height_ratio: f32,
	max_width: f32,
	allocator := context.allocator,
) -> []Laid_Block {
	context.allocator = allocator
	lh := text_pkg.line_height(base_font_size, line_height_ratio)
	out: [dynamic]Laid_Block

	for blk in blocks {
		boxes: [dynamic]Span_Box
		cursor_x: f32 = 0
		cursor_y: f32 = 0
		first_unit_on_line := true

		emit :: proc(boxes: ^[dynamic]Span_Box, style: Span_Style, text: string,
		             font_obj: rl.Font, font_size: f32, lh: f32,
		             cursor_x: ^f32, cursor_y: ^f32, max_width: f32,
		             first_unit_on_line: ^bool) {
			if len(text) == 0 do return
			cstr := strings.clone_to_cstring(text, context.temp_allocator)
			size := rl.MeasureTextEx(font_obj, cstr, font_size, 0)
			w := size.x
			if !first_unit_on_line^ && cursor_x^ + w > max_width {
				cursor_x^ = 0
				cursor_y^ += lh
				first_unit_on_line^ = true
			}
			append(boxes, Span_Box{
				style = style, text = text,
				x = cursor_x^, y = cursor_y^,
				width = w, height = lh,
			})
			cursor_x^ += w
			first_unit_on_line^ = false
		}

		for span in blk.spans {
			fnt := font_for(span.style, base_font_name)
			text := span.text
			start := 0
			i := 0
			for i < len(text) {
				ch := text[i]
				if ch == '\n' {
					// Flush pending word.
					if i > start {
						emit(&boxes, span.style, text[start:i], fnt,
							base_font_size, lh, &cursor_x, &cursor_y, max_width,
							&first_unit_on_line)
					}
					// Forced break.
					cursor_x = 0
					cursor_y += lh
					first_unit_on_line = true
					i += 1
					start = i
					continue
				}
				if ch == ' ' || ch == '\t' {
					if i > start {
						emit(&boxes, span.style, text[start:i], fnt,
							base_font_size, lh, &cursor_x, &cursor_y, max_width,
							&first_unit_on_line)
					}
					ws := text[i:i+1]
					i += 1
					if first_unit_on_line {
						// Drop whitespace at line start.
						start = i
						continue
					}
					emit(&boxes, span.style, ws, fnt, base_font_size, lh,
						&cursor_x, &cursor_y, max_width, &first_unit_on_line)
					start = i
					continue
				}
				i += 1
			}
			if start < len(text) {
				emit(&boxes, span.style, text[start:], fnt, base_font_size, lh,
					&cursor_x, &cursor_y, max_width, &first_unit_on_line)
			}
		}

		block_height := cursor_y + lh
		append(&out, Laid_Block{
			spans = boxes[:],
			total_height = block_height,
		})
	}
	return out[:]
}

// Free per-block allocations from a Laid_Block slice.
// Not needed when callers used context.temp_allocator (auto-freed each frame).
free_laid :: proc(laid: []Laid_Block) {
	for blk in laid {
		delete(blk.spans)
	}
	delete(laid)
}

// Draw a laid-out markdown tree into `rect` using `color` for non-code spans.
// Code spans get a subtle dark bg fill.
draw :: proc(laid: []Laid_Block, rect: rl.Rectangle, color: rl.Color, base_font_size: f32, base_font_name: string, line_height_ratio: f32) {
	lh := text_pkg.line_height(base_font_size, line_height_ratio)
	code_bg := rl.Color{60, 60, 70, 255}

	block_y_offset: f32 = 0
	for blk, blk_idx in laid {
		for span in blk.spans {
			x := rect.x + span.x
			y := rect.y + block_y_offset + span.y
			fnt := font_for(span.style, base_font_name)

			if span.style == .Code {
				rl.DrawRectangleRec(rl.Rectangle{x, y, span.width, lh}, code_bg)
			}

			cstr := strings.clone_to_cstring(span.text, context.temp_allocator)
			rl.DrawTextEx(fnt, cstr, rl.Vector2{x, y}, base_font_size, 0, color)
		}
		block_y_offset += blk.total_height
		if blk_idx + 1 < len(laid) {
			block_y_offset += lh  // paragraph spacing
		}
	}
}
