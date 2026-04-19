package text

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

// Cross-frame cache for wrapped-text heights. Keyed by content.data
// pointer: as long as Bridge hasn't re-flattened the tree, the same
// NodeText has the same pointer each frame and the cache hits. On
// re-flatten, Bridge calls invalidate_height_cache so stale pointers
// never return a false positive if an address is reused.
Height_Key :: struct {
	content_ptr: uintptr,
	content_len: int,
	font_size:   f32,
	width:       f32,
	lh_ratio:    f32,
	font_tex_id: u32,
}
@(private)
height_cache: map[Height_Key]f32

lookup_height :: proc(key: Height_Key) -> (f32, bool) {
	h, ok := height_cache[key]
	return h, ok
}

cache_height :: proc(key: Height_Key, h: f32) {
	height_cache[key] = h
}

invalidate_height_cache :: proc() {
	clear(&height_cache)
}

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

// Raw advance width of a single codepoint in `font`'s base units.
// Multiply by `font_size / font.baseSize` to get pixels at a target size.
// Mirrors the inner arithmetic of rl.MeasureTextEx so compute_lines can
// track a running width in O(n) rather than remeasuring the growing
// line prefix on every character.
@(private)
glyph_advance_raw :: proc(font_obj: rl.Font, cp: rune) -> f32 {
	idx := rl.GetGlyphIndex(font_obj, cp)
	if idx < 0 || idx >= font_obj.glyphCount do return 0
	advance := font_obj.glyphs[idx].advanceX
	if advance != 0 do return f32(advance)
	return font_obj.recs[idx].width
}

// Compute visual line breaks for text with word-wrap and \n support.
// max_width <= 0 means no wrapping (only break on \n).
//
// Tracks a running `current_px` equal to the pixel width from line_start
// to pos. Each character contributes exactly one glyph advance, making
// this O(n). Matches rl.MeasureTextEx semantics: scale by
// font_size / baseSize and add `spacing` between (not before) glyphs.
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

	scale: f32 = 1
	if font_obj.baseSize > 0 {
		scale = font_size / f32(font_obj.baseSize)
	}

	line_start := 0
	last_space := -1          // byte offset of last space (word break point)
	last_space_width: f32 = 0 // line width up to (not including) last_space
	current_px: f32 = 0        // pixel width of [line_start, pos)
	char_count := 0            // chars added to the current line (spacing gate)

	pos := 0
	for pos < len(text) {
		c := text[pos]

		// Hard line break
		if c == '\n' {
			append(&lines, Text_Line{start = line_start, end = pos, width = current_px})
			pos += 1
			line_start = pos
			current_px = 0
			char_count = 0
			last_space = -1
			continue
		}

		rune_val, size := utf8.decode_rune(transmute([]u8)text[pos:])

		// Record space boundary BEFORE adding its width; last_space_width
		// is the line width up to (but not including) the space.
		if c == ' ' {
			last_space = pos
			last_space_width = current_px
		}

		glyph_px := glyph_advance_raw(font_obj, rune_val) * scale
		next_px := current_px + glyph_px
		if char_count > 0 do next_px += spacing

		// Wrap if the candidate width would exceed max_width. The
		// `pos > line_start` guard prevents an infinite loop on a line
		// whose very first char is already wider than max_width.
		if max_width > 0 && next_px > max_width && pos > line_start {
			if last_space >= line_start {
				// Break at last word boundary; skip the space.
				append(&lines, Text_Line{
					start = line_start,
					end   = last_space,
					width = last_space_width,
				})
				line_start = last_space + 1
				pos = line_start
				current_px = 0
				char_count = 0
				last_space = -1
				continue
			}

			// No space on this line — break at char boundary. The
			// current char becomes the first char of the new line, so
			// don't advance pos; the next iteration handles it.
			append(&lines, Text_Line{start = line_start, end = pos, width = current_px})
			line_start = pos
			current_px = 0
			char_count = 0
			last_space = -1
			continue
		}

		current_px = next_px
		char_count += 1
		pos += size
	}

	// Emit final line
	append(&lines, Text_Line{start = line_start, end = len(text), width = current_px})

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

// Compute line height from font size. `ratio` is the theme line-height
// (font_size * ratio). Pass 0 to use the default (`font_size + 4`).
line_height :: proc(font_size: f32, ratio: f32 = 0) -> f32 {
	if ratio > 0 do return font_size * ratio
	return font_size + 4
}
