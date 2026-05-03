package font

import rl "vendor:raylib"

Font_Style :: enum {
	Regular,
	Bold,
	Italic,
}

Font_Key :: struct {
	name:  string,
	style: Font_Style,
}

fonts: map[Font_Key]rl.Font
default_font_name: string

init :: proc() {
	fonts = make(map[Font_Key]rl.Font)
	default_font_name = "sans"
	load_embedded()
}

destroy :: proc() {
	for _, f in fonts {
		rl.UnloadFont(f)
	}
	delete(fonts)
}

register :: proc(name: string, style: Font_Style, f: rl.Font) {
	key := Font_Key{name = name, style = style}
	if existing, ok := fonts[key]; ok {
		rl.UnloadFont(existing)
	}
	fonts[key] = f
}

get :: proc(name: string, style: Font_Style) -> rl.Font {
	if f, ok := fonts[Font_Key{name, style}]; ok {
		return f
	}
	if style != .Regular {
		if f, ok := fonts[Font_Key{name, .Regular}]; ok {
			return f
		}
	}
	if name != default_font_name {
		if f, ok := fonts[Font_Key{default_font_name, style}]; ok {
			return f
		}
	}
	if name != default_font_name || style != .Regular {
		if f, ok := fonts[Font_Key{default_font_name, .Regular}]; ok {
			return f
		}
	}
	return rl.GetFontDefault()
}

style_from_weight :: proc(weight: Font_Weight) -> Font_Style {
	switch weight {
	case .BOLD:
		return .Bold
	case .ITALIC:
		return .Italic
	case .NORMAL:
		return .Regular
	}
	return .Regular
}

Font_Weight :: enum {
	NORMAL,
	BOLD,
	ITALIC,
}
