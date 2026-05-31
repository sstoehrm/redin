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

// #162 M1: the original guard split on '/' only, so on a Windows host a
// theme PUT with a backslash path slipped past the `..`-segment check and
// the file was opened by the font loader. Reject backslashes, drive-letter
// prefixes, and UNC paths outright so the guard holds regardless of host.
@(test)
test_validate_font_path_rejects_windows_escapes :: proc(t: ^testing.T) {
	testing.expect(t, !validate_font_path("..\\..\\Windows\\System32\\drivers\\etc\\hosts"),
		"backslash parent traversal should be rejected")
	testing.expect(t, !validate_font_path("a\\b"), "any backslash should be rejected")
	testing.expect(t, !validate_font_path("C:\\Windows\\Fonts\\arial.ttf"),
		"drive-letter + backslash path should be rejected")
	testing.expect(t, !validate_font_path("C:/Windows/Fonts/arial.ttf"),
		"drive-letter path with forward slashes should be rejected")
	testing.expect(t, !validate_font_path("\\\\server\\share\\font.ttf"),
		"UNC path should be rejected")
	// Ordinary relative paths must still pass.
	testing.expect(t, validate_font_path("assets/my-font.ttf"),
		"ordinary relative path still allowed")
}
