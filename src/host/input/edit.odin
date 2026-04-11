package input

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"
import text_pkg "../text"

// --- UTF-8 cursor helpers ---

next_char :: proc(text: []u8, pos: int) -> int {
	if pos >= len(text) do return pos
	_, size := utf8.decode_rune(text[pos:])
	return min(pos + size, len(text))
}

prev_char :: proc(text: []u8, pos: int) -> int {
	if pos <= 0 do return 0
	i := pos - 1
	for i > 0 && (text[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}

next_word :: proc(text: []u8, pos: int) -> int {
	p := pos
	for p < len(text) {
		r, size := utf8.decode_rune(text[p:])
		if !is_word_char(r) do break
		p += size
	}
	for p < len(text) {
		r, size := utf8.decode_rune(text[p:])
		if is_word_char(r) do break
		p += size
	}
	return p
}

prev_word :: proc(text: []u8, pos: int) -> int {
	p := pos
	for p > 0 {
		prev := prev_char(text, p)
		r, _ := utf8.decode_rune(text[prev:])
		if is_word_char(r) do break
		p = prev
	}
	for p > 0 {
		prev := prev_char(text, p)
		r, _ := utf8.decode_rune(text[prev:])
		if !is_word_char(r) do break
		p = prev
	}
	return p
}

is_word_char :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
	       (r >= '0' && r <= '9') || r == '_'
}

// --- Selection helpers ---

clear_selection :: proc() {
	state.selection_start = -1
	state.selection_end = -1
}

start_or_extend_selection :: proc(anchor: int, cursor: int) {
	if state.selection_start < 0 {
		state.selection_start = anchor
	}
	state.selection_end = cursor
	if state.selection_start == state.selection_end {
		clear_selection()
	}
}

delete_selection :: proc() {
	if !has_selection() do return
	lo, hi := selection_range()
	ordered_remove_range(&state.text, lo, hi)
	state.cursor = lo
	clear_selection()
}

// --- Core edit operations ---

insert_char :: proc(char: rune) {
	if has_selection() {
		delete_selection()
	}
	buf, n := utf8.encode_rune(char)
	inject_at(&state.text, state.cursor, ..buf[:n])
	state.cursor += n
}

insert_string :: proc(s: string) {
	if has_selection() {
		delete_selection()
	}
	bytes := transmute([]u8)s
	inject_at(&state.text, state.cursor, ..bytes)
	state.cursor += len(bytes)
}

delete_back_char :: proc() {
	if has_selection() {
		delete_selection()
		return
	}
	if state.cursor <= 0 do return
	prev := prev_char(state.text[:], state.cursor)
	ordered_remove_range(&state.text, prev, state.cursor)
	state.cursor = prev
}

delete_forward_char :: proc() {
	if has_selection() {
		delete_selection()
		return
	}
	if state.cursor >= len(state.text) do return
	next := next_char(state.text[:], state.cursor)
	ordered_remove_range(&state.text, state.cursor, next)
}

delete_back_word :: proc() {
	if has_selection() {
		delete_selection()
		return
	}
	if state.cursor <= 0 do return
	target := prev_word(state.text[:], state.cursor)
	ordered_remove_range(&state.text, target, state.cursor)
	state.cursor = target
}

delete_forward_word :: proc() {
	if has_selection() {
		delete_selection()
		return
	}
	if state.cursor >= len(state.text) do return
	target := next_word(state.text[:], state.cursor)
	ordered_remove_range(&state.text, state.cursor, target)
}

// --- Movement ---

move_left :: proc(shift: bool) {
	old_cursor := state.cursor
	if !shift && has_selection() {
		lo, _ := selection_range()
		state.cursor = lo
		clear_selection()
		return
	}
	state.cursor = prev_char(state.text[:], state.cursor)
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	}
}

move_right :: proc(shift: bool) {
	old_cursor := state.cursor
	if !shift && has_selection() {
		_, hi := selection_range()
		state.cursor = hi
		clear_selection()
		return
	}
	state.cursor = next_char(state.text[:], state.cursor)
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	}
}

move_word_left :: proc(shift: bool) {
	old_cursor := state.cursor
	if !shift && has_selection() {
		lo, _ := selection_range()
		state.cursor = lo
		clear_selection()
		return
	}
	state.cursor = prev_word(state.text[:], state.cursor)
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	}
}

move_word_right :: proc(shift: bool) {
	old_cursor := state.cursor
	if !shift && has_selection() {
		_, hi := selection_range()
		state.cursor = hi
		clear_selection()
		return
	}
	state.cursor = next_word(state.text[:], state.cursor)
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	}
}

move_home :: proc(shift: bool) {
	old_cursor := state.cursor
	if !shift {
		clear_selection()
	}
	state.cursor = 0
	if shift {
		start_or_extend_selection(old_cursor, 0)
	}
}

move_end :: proc(shift: bool) {
	old_cursor := state.cursor
	if !shift {
		clear_selection()
	}
	state.cursor = len(state.text)
	if shift {
		start_or_extend_selection(old_cursor, len(state.text))
	}
}

select_all :: proc() {
	state.selection_start = 0
	state.selection_end = len(state.text)
	state.cursor = len(state.text)
}

// --- Clipboard ---

copy_selection :: proc() {
	if !has_selection() do return
	lo, hi := selection_range()
	text := string(state.text[lo:hi])
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	rl.SetClipboardText(cstr)
}

cut_selection :: proc() {
	copy_selection()
	delete_selection()
}

paste :: proc() {
	clip := rl.GetClipboardText()
	if clip == nil do return
	s := string(clip)
	if len(s) == 0 do return
	insert_string(s)
}

// --- Click to position ---

click_to_cursor :: proc(text: []u8, click_x: f32, font_obj: rl.Font, font_size: f32, spacing: f32) -> int {
	if len(text) == 0 do return 0
	best_pos := 0
	best_dist: f32 = abs(click_x)
	pos := 0
	for pos < len(text) {
		_, size := utf8.decode_rune(text[pos:])
		pos += size
		cstr := strings.clone_to_cstring(string(text[:pos]), context.temp_allocator)
		measured := rl.MeasureTextEx(font_obj, cstr, font_size, spacing)
		dist := abs(click_x - measured.x)
		if dist < best_dist {
			best_dist = dist
			best_pos = pos
		}
	}
	return best_pos
}

// --- Line-aware movement (requires layout lines) ---

// Move cursor up one visual line, preserving X position.
move_up :: proc(lines: []text_pkg.Text_Line, text_str: string, font_obj: rl.Font, font_size: f32, sp: f32, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	if line_idx <= 0 {
		state.cursor = 0
	} else {
		cur_line := lines[line_idx]
		x := text_pkg.measure_range(text_str, cur_line.start, state.cursor, font_obj, font_size, sp)
		prev_line := lines[line_idx - 1]
		state.cursor = x_to_cursor_in_line(text_str, prev_line, x, font_obj, font_size, sp)
	}
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Move cursor down one visual line, preserving X position.
move_down :: proc(lines: []text_pkg.Text_Line, text_str: string, font_obj: rl.Font, font_size: f32, sp: f32, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	if line_idx >= len(lines) - 1 {
		state.cursor = len(state.text)
	} else {
		cur_line := lines[line_idx]
		x := text_pkg.measure_range(text_str, cur_line.start, state.cursor, font_obj, font_size, sp)
		next_line := lines[line_idx + 1]
		state.cursor = x_to_cursor_in_line(text_str, next_line, x, font_obj, font_size, sp)
	}
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Move cursor to start of current visual line.
move_home_line :: proc(lines: []text_pkg.Text_Line, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	state.cursor = lines[line_idx].start
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Move cursor to end of current visual line.
move_end_line :: proc(lines: []text_pkg.Text_Line, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	state.cursor = lines[line_idx].end
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Find byte offset in a line closest to a given X pixel position.
x_to_cursor_in_line :: proc(text_str: string, line: text_pkg.Text_Line, target_x: f32, font_obj: rl.Font, font_size: f32, sp: f32) -> int {
	if line.start >= line.end do return line.start
	best_pos := line.start
	best_dist := abs(target_x)

	pos := line.start
	for pos < line.end {
		_, size := utf8.decode_rune(transmute([]u8)text_str[pos:])
		pos += size
		w := text_pkg.measure_range(text_str, line.start, pos, font_obj, font_size, sp)
		dist := abs(target_x - w)
		if dist < best_dist {
			best_dist = dist
			best_pos = pos
		}
	}
	return best_pos
}

// --- Dynamic array helper ---

ordered_remove_range :: proc(arr: ^[dynamic]u8, lo: int, hi: int) {
	if lo >= hi do return
	count := hi - lo
	copy(arr[lo:], arr[hi:])
	resize(arr, len(arr) - count)
}
