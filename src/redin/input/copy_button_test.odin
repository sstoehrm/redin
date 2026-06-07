package input

import "core:testing"
import "../types"

@(test)
test_button_clipboard_text_present :: proc(t: ^testing.T) {
	n := types.NodeButton{copy_text = "hello"}
	text, ok := button_clipboard_text(n)
	testing.expect(t, ok, "button with copy_text must report ok")
	testing.expect_value(t, text, "hello")
}

@(test)
test_button_clipboard_text_absent :: proc(t: ^testing.T) {
	n := types.NodeButton{click = "x/click"}
	text, ok := button_clipboard_text(n)
	testing.expect(t, !ok, "button without copy_text must report not-ok")
	testing.expect_value(t, text, "")
}
