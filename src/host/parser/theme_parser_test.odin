package parser

import "core:testing"
import "../types"

@(test)
test_parse_theme_basic :: proc(t: ^testing.T) {
	input := `{:button {:bg [76 86 106] :color [236 239 244] :radius 6}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, len(theme), 1)
	btn, found := theme["button"]
	testing.expect(t, found, "should have 'button' key")
	testing.expect_value(t, btn.bg, [3]u8{76, 86, 106})
	testing.expect_value(t, btn.color, [3]u8{236, 239, 244})
	testing.expect_value(t, btn.radius, 6)
}

@(test)
test_parse_theme_padding :: proc(t: ^testing.T) {
	input := `{:surface {:padding [8 12 8 12]}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	s := theme["surface"]
	testing.expect_value(t, s.padding, [4]u8{8, 12, 8, 12})
}

@(test)
test_parse_theme_font_size :: proc(t: ^testing.T) {
	input := `{:heading {:font-size 24}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, theme["heading"].font_size, 24)
}

@(test)
test_parse_theme_weight_keyword :: proc(t: ^testing.T) {
	input := `{:heading {:weight :bold}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, theme["heading"].weight, types.FontWeight.BOLD)
}

@(test)
test_parse_theme_weight_number :: proc(t: ^testing.T) {
	input := `{:heading {:weight 1}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, theme["heading"].weight, types.FontWeight.BOLD)
}

@(test)
test_parse_theme_border_width :: proc(t: ^testing.T) {
	input := `{:input {:border [76 86 106] :border-width 1}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	inp := theme["input"]
	testing.expect_value(t, inp.border, [3]u8{76, 86, 106})
	testing.expect_value(t, inp.border_width, 1)
}

@(test)
test_parse_theme_multiple_aspects :: proc(t: ^testing.T) {
	input := `{:button {:bg [76 86 106]} :button#hover {:bg [94 105 126]}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, len(theme), 2)
	_, has_base := theme["button"]
	testing.expect(t, has_base, "should have base aspect")
	_, has_hover := theme["button#hover"]
	testing.expect(t, has_hover, "should have hover variant")
	testing.expect_value(t, theme["button#hover"].bg, [3]u8{94, 105, 126})
}

@(test)
test_parse_theme_with_comments :: proc(t: ^testing.T) {
	input := `{;; This is a comment
   :body {:font-size 14 :color [216 222 233]}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, theme["body"].font_size, 14)
}

@(test)
test_parse_theme_empty :: proc(t: ^testing.T) {
	input := `{}`
	theme, ok := _parse_theme_string(input)
	defer delete(theme)
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, len(theme), 0)
}

// Helper: parse theme from string (wraps the file-based loader logic)
_parse_theme_string :: proc(input: string) -> (map[string]types.Theme, bool) {
	p := _Parser{text = input, pos = 0}

	// Skip to first '{'
	for p.pos < len(p.text) && p.text[p.pos] != '{' {
		p.pos += 1
	}
	if p.pos >= len(p.text) do return {}, false
	p.pos += 1

	theme := make(map[string]types.Theme)

	for {
		c := _peek(&p)
		if c == '}' || c == 0 do break
		if c == ':' {
			key := _read_keyword(&p)
			_skip_ws(&p)
			if _peek(&p) == '{' {
				t := _parse_theme_props(&p)
				cs := make([]u8, len(key))
				copy(cs, key)
				theme[string(cs)] = t
			}
		} else {
			p.pos += 1
		}
	}

	return theme, true
}
