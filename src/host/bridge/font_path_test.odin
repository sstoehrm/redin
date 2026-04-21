package bridge

import "core:testing"

@(test)
test_validate_font_path_accepts_relative :: proc(t: ^testing.T) {
	testing.expect(t, validate_font_path("assets/Font.ttf"))
	testing.expect(t, validate_font_path("Font.ttf"))
	testing.expect(t, validate_font_path("a/b/c/Font.ttf"))
	testing.expect(t, validate_font_path("fonts/MyFont-Bold.ttf"))
}

@(test)
test_validate_font_path_rejects_absolute :: proc(t: ^testing.T) {
	testing.expect(t, !validate_font_path("/etc/passwd"))
	testing.expect(t, !validate_font_path("/tmp/x.ttf"))
	testing.expect(t, !validate_font_path("/"))
}

@(test)
test_validate_font_path_rejects_parent_segments :: proc(t: ^testing.T) {
	testing.expect(t, !validate_font_path("../Font.ttf"))
	testing.expect(t, !validate_font_path("a/../b/Font.ttf"))
	testing.expect(t, !validate_font_path("fonts/../../etc/passwd"))
}

@(test)
test_validate_font_path_allows_embedded_dots :: proc(t: ^testing.T) {
	// Filenames with dots that aren't a `..` segment must pass.
	testing.expect(t, validate_font_path("foo..bar/Font.ttf"))
	testing.expect(t, validate_font_path("assets/My.Font.ttf"))
	testing.expect(t, validate_font_path(".hidden/Font.ttf"))
}

@(test)
test_validate_font_path_rejects_empty_and_nul :: proc(t: ^testing.T) {
	testing.expect(t, !validate_font_path(""))
	testing.expect(t, !validate_font_path("a\x00b/Font.ttf"))
}
