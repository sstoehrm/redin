package parser

import "../types"
import "core:fmt"
import "core:os"
import "core:strings"

load_theme :: proc(
	filepath: string,
) -> (
	theme: map[string]types.Theme,
	ok: bool,
) {
	data, err := os.read_entire_file(filepath, context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to read %s", filepath)
		return {}, false
	}
	defer delete(data)

	p := _Parser {
		text = string(data),
		pos  = 0,
	}

	// Skip to first '{' (past the `(redin.set_theme` wrapper)
	for p.pos < len(p.text) && p.text[p.pos] != '{' {
		p.pos += 1
	}
	if p.pos >= len(p.text) do return {}, false
	p.pos += 1

	theme = make(map[string]types.Theme)

	for {
		c := _peek(&p)
		if c == '}' || c == 0 do break
		if c == ':' {
			key := _read_keyword(&p)
			_skip_ws(&p)
			if _peek(&p) == '{' {
				t := _parse_theme_props(&p)
				theme[strings.clone(key)] = t
			}
		} else {
			p.pos += 1
		}
	}

	return theme, true
}

_parse_theme_props :: proc(p: ^_Parser) -> types.Theme {
	p.pos += 1 // skip '{'
	t: types.Theme

	for {
		c := _peek(p)
		if c == '}' {
			p.pos += 1
			break
		}
		if c == 0 do break
		if c == ':' {
			key := _read_keyword(p)
			_skip_ws(p)

			switch key {
			case "bg":
				t.bg = _parse_rgb(p)
			case "color":
				t.color = _parse_rgb(p)
			case "padding":
				t.padding = _parse_padding(p)
			case "border":
				t.border = _parse_rgb(p)
			case "border-width":
				t.border_width = u8(_read_number(p))
			case "radius":
				t.radius = u8(_read_number(p))
			case "font-size":
				t.font_size = f16(_read_number(p))
			case "font":
				c2 := _peek(p)
				if c2 == ':' {
					t.font = strings.clone(_read_keyword(p))
				} else if c2 == '"' {
					t.font = strings.clone(_read_string(p))
				}
			case "weight":
				c2 := _peek(p)
				if c2 == ':' {
					w := _read_keyword(p)
					if w == "bold" do t.weight = 1
					else if w == "italic" do t.weight = 2
				} else if c2 >= '0' && c2 <= '9' {
					t.weight = u8(_read_number(p))
				}
			case "opacity":
				t.opacity = _read_number(p)
			case "selection":
				t.selection = _parse_rgba(p)
			}
		} else {
			p.pos += 1
		}
	}

	return t
}

_parse_rgb :: proc(p: ^_Parser) -> [3]u8 {
	_skip_ws(p)
	if p.pos < len(p.text) && p.text[p.pos] == '[' {
		p.pos += 1
		_skip_ws(p)
		r := u8(_read_number(p))
		_skip_ws(p)
		g := u8(_read_number(p))
		_skip_ws(p)
		b := u8(_read_number(p))
		_skip_ws(p)
		if p.pos < len(p.text) && p.text[p.pos] == ']' do p.pos += 1
		return {r, g, b}
	}
	return {}
}

_parse_rgba :: proc(p: ^_Parser) -> [4]u8 {
	_skip_ws(p)
	if p.pos < len(p.text) && p.text[p.pos] == '[' {
		p.pos += 1
		_skip_ws(p)
		r := u8(_read_number(p))
		_skip_ws(p)
		g := u8(_read_number(p))
		_skip_ws(p)
		b := u8(_read_number(p))
		_skip_ws(p)
		a := u8(_read_number(p))
		_skip_ws(p)
		if p.pos < len(p.text) && p.text[p.pos] == ']' do p.pos += 1
		return {r, g, b, a}
	}
	return {}
}

_parse_padding :: proc(p: ^_Parser) -> [4]u8 {
	_skip_ws(p)
	if p.pos < len(p.text) && p.text[p.pos] == '[' {
		p.pos += 1
		_skip_ws(p)
		top := u8(_read_number(p))
		_skip_ws(p)
		right := u8(_read_number(p))
		_skip_ws(p)
		bottom := u8(_read_number(p))
		_skip_ws(p)
		left := u8(_read_number(p))
		_skip_ws(p)
		if p.pos < len(p.text) && p.text[p.pos] == ']' do p.pos += 1
		return {top, right, bottom, left}
	}
	return {}
}
