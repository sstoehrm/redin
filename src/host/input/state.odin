package input

Selection_Kind :: enum u8 {
	None,
	Input,
	Text,
}

Input_State :: struct {
	text:            [dynamic]u8,
	cursor:          int,    // byte offset
	selection_start: int,    // byte offset, -1 = no selection
	selection_end:   int,    // byte offset, -1 = no selection
	scroll_offset_x: f32,
	scroll_offset_y: f32,
	last_dispatched: string,
	active:          bool,
	selection_kind:  Selection_Kind,
	selection_path:  [dynamic]u8,  // owned copy of types.Path.value
}

state: Input_State

state_init :: proc() {
	state.selection_start = -1
	state.selection_end = -1
	state.selection_kind = .None
}

state_destroy :: proc() {
	delete(state.text)
	if len(state.last_dispatched) > 0 {
		delete(state.last_dispatched)
	}
	delete(state.selection_path)
}

// Called when an input gains focus. Copies the node's value into the editing buffer.
focus_enter :: proc(value: string) {
	clear_text_selection()
	clear(&state.text)
	append(&state.text, ..transmute([]u8)value)
	state.cursor = len(state.text)
	state.selection_start = -1
	state.selection_end = -1
	state.scroll_offset_x = 0
	state.scroll_offset_y = 0
	state.selection_kind = .Input
	state.active = true
	if len(state.last_dispatched) > 0 {
		delete(state.last_dispatched)
	}
	state.last_dispatched = strings_clone(value)
}

// Sets a text-node selection (not an input field). Copies path into owned storage.
set_text_selection :: proc(path: []u8, lo, hi: int) {
	clear(&state.selection_path)
	append(&state.selection_path, ..path)
	state.selection_start = lo
	state.selection_end   = hi
	state.selection_kind  = .Text
}

// Clears any text-node selection and frees the owned path storage.
clear_text_selection :: proc() {
	clear(&state.selection_path)
	state.selection_kind = .None
}

// Returns a view into the owned path slice (no allocation).
text_selection_path :: proc() -> []u8 {
	return state.selection_path[:]
}

// Called when the input loses focus.
focus_leave :: proc() {
	state.active = false
}

// Controlled sync: if Fennel changed the value, update the buffer.
// Call once per frame while active. Returns true if the buffer was replaced.
controlled_sync :: proc(node_value: string) -> bool {
	if !state.active do return false
	if node_value == state.last_dispatched do return false

	// Fennel transformed the value — replace buffer
	clear(&state.text)
	append(&state.text, ..transmute([]u8)node_value)
	state.cursor = min(state.cursor, len(state.text))
	if state.selection_start >= 0 {
		state.selection_start = min(state.selection_start, len(state.text))
		state.selection_end = min(state.selection_end, len(state.text))
		if state.selection_start == state.selection_end {
			state.selection_start = -1
			state.selection_end = -1
		}
	}
	if len(state.last_dispatched) > 0 {
		delete(state.last_dispatched)
	}
	state.last_dispatched = strings_clone(node_value)
	return true
}

// Get the current text as a string (view into the dynamic array, no allocation).
get_text :: proc() -> string {
	return string(state.text[:])
}

// Returns true if there is an active selection.
has_selection :: proc() -> bool {
	return state.selection_start >= 0 && state.selection_start != state.selection_end
}

// Returns the ordered selection range (lo, hi).
selection_range :: proc() -> (int, int) {
	if state.selection_start <= state.selection_end {
		return state.selection_start, state.selection_end
	}
	return state.selection_end, state.selection_start
}

// Helper: clone a string.
strings_clone :: proc(s: string) -> string {
	if len(s) == 0 do return ""
	buf := make([]u8, len(s))
	copy(buf, transmute([]u8)s)
	return string(buf)
}

