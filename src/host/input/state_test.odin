package input

import "core:testing"

@(test)
test_set_text_selection_stores_path_copy :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()

	src := []u8{0x01, 0x02, 0x03, 0x04}
	set_text_selection(src, 2, 5)

	testing.expect_value(t, state.selection_kind, Selection_Kind.Text)
	testing.expect_value(t, state.selection_start, 2)
	testing.expect_value(t, state.selection_end, 5)
	testing.expect_value(t, len(state.selection_path), 4)

	src[0] = 0xFF
	testing.expect_value(t, state.selection_path[0], u8(0x01))
}

@(test)
test_clear_text_selection_frees_path :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()

	src := []u8{0x10, 0x20}
	set_text_selection(src, 0, 0)
	clear_text_selection()

	testing.expect_value(t, state.selection_kind, Selection_Kind.None)
	testing.expect_value(t, len(state.selection_path), 0)
}

@(test)
test_clear_text_selection_resets_has_selection :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()
	set_text_selection([]u8{0x01}, 3, 7)
	testing.expect(t, has_selection(), "should have selection after set")
	clear_text_selection()
	testing.expect(t, !has_selection(), "should not have selection after clear")
}

@(test)
test_focus_enter_clears_text_selection :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()
	set_text_selection([]u8{0xAA}, 0, 1)
	focus_enter("buf")
	testing.expect_value(t, state.selection_kind, Selection_Kind.Input)
	testing.expect_value(t, len(state.selection_path), 0)
}
