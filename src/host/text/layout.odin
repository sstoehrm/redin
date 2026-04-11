package text

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

Text_Line :: struct {
	start: int, // byte offset inclusive
	end:   int, // byte offset exclusive
	width: f32, // rendered pixel width
}

// Measure pixel width of a substring.
measure_range :: proc(text: string, start: int, end: int, font_obj: rl.Font, font_size: f32, spacing: f32) -> f32 {
	if start >= end do return 0
	cstr := strings.clone_to_cstring(text[start:end], context.temp_allocator)
	return rl.MeasureTextEx(font_obj, cstr, font_size, spacing).x
}

// Compute visual line breaks for text with word-wrap and \n support.
// max_width <= 0 means no wrapping (only break on \n).
compute_lines :: proc(
	text: string,
	font_obj: rl.Font,
	font_size: f32,
	spacing: f32,
	max_width: f32,
) -> [dynamic]Text_Line {
	lines: [dynamic]Text_Line

	if len(text) == 0 {
		append(&lines, Text_Line{start = 0, end = 0, width = 0})
		return lines
	}

	line_start := 0
	last_space := -1          // byte offset of last space (word break point)
	last_space_width: f32 = 0 // line width up to (not including) last_space

	pos := 0
	for pos < len(text) {
		// Hard line break
		if text[pos] == '\n' {
			w := measure_range(text, line_start, pos, font_obj, font_size, spacing)
			append(&lines, Text_Line{start = line_start, end = pos, width = w})
			pos += 1
			line_start = pos
			last_space = -1
			continue
		}

		// Track word boundaries
		if text[pos] == ' ' {
			last_space = pos
			last_space_width = measure_range(text, line_start, pos, font_obj, font_size, spacing)
		}

		// Advance past this character
		_, size := utf8.decode_rune(transmute([]u8)text[pos:])
		next_pos := pos + size

		// Check if line exceeds max_width
		if max_width > 0 && next_pos > line_start {
			line_width := measure_range(text, line_start, next_pos, font_obj, font_size, spacing)
			if line_width > max_width && pos > line_start {
				if last_space >= line_start {
					// Break at last word boundary
					append(&lines, Text_Line{
						start = line_start,
						end   = last_space,
						width = last_space_width,
					})
					line_start = last_space + 1 // skip the space
					last_space = -1
				} else {
					// No word boundary — break at character level
					w := measure_range(text, line_start, pos, font_obj, font_size, spacing)
					append(&lines, Text_Line{start = line_start, end = pos, width = w})
					line_start = pos
					last_space = -1
				}
			}
		}

		pos = next_pos
	}

	// Emit final line
	w := measure_range(text, line_start, len(text), font_obj, font_size, spacing)
	append(&lines, Text_Line{start = line_start, end = len(text), width = w})

	return lines
}

// Map a byte offset (cursor) to a visual line index and byte offset within that line.
cursor_to_line :: proc(lines: []Text_Line, cursor: int) -> (line_idx: int, col_offset: int) {
	for i := 0; i < len(lines); i += 1 {
		line := lines[i]
		if cursor <= line.end || i == len(lines) - 1 {
			return i, cursor - line.start
		}
	}
	return len(lines) - 1, 0
}

// Map a click position (relative to content area top-left) to a byte offset.
point_to_cursor :: proc(
	lines: []Text_Line,
	text: string,
	x: f32,
	y: f32,
	font_obj: rl.Font,
	font_size: f32,
	spacing: f32,
	lh: f32,
	scroll_x: f32,
	scroll_y: f32,
) -> int {
	if len(lines) == 0 do return 0

	adjusted_y := y + scroll_y
	line_idx := int(adjusted_y / lh)
	if line_idx < 0 do line_idx = 0
	if line_idx >= len(lines) do line_idx = len(lines) - 1

	line := lines[line_idx]
	if line.start >= line.end do return line.start

	adjusted_x := x + scroll_x
	best_pos := line.start
	best_dist := abs(adjusted_x)

	pos := line.start
	for pos < line.end {
		_, size := utf8.decode_rune(transmute([]u8)text[pos:])
		pos += size
		w := measure_range(text, line.start, pos, font_obj, font_size, spacing)
		dist := abs(adjusted_x - w)
		if dist < best_dist {
			best_dist = dist
			best_pos = pos
		}
	}

	return best_pos
}

// Compute line height from font size.
line_height :: proc(font_size: f32) -> f32 {
	return font_size + 4
}
