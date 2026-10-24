package font

import rl "vendor:raylib"

inter_regular      := #load("Inter-Regular.ttf")
inter_bold         := #load("Inter-Bold.ttf")
inter_italic       := #load("Inter-Italic.ttf")
fira_code_regular  := #load("FiraCode-Regular.ttf")
fira_code_bold     := #load("FiraCode-Bold.ttf")
noto_serif_regular := #load("NotoSerif-Regular.ttf")
noto_serif_bold    := #load("NotoSerif-Bold.ttf")
noto_serif_italic  := #load("NotoSerif-Italic.ttf")

DEFAULT_FONT_SIZE :: 64

load_embedded :: proc() {
	load_font :: proc(name: string, style: Font_Style, data: []u8) {
		// Explicit glyph set (codepoints.odin): with nil/0 raylib loads
		// ASCII 32..126 only and every other character renders as '?'.
		f := rl.LoadFontFromMemory(".ttf", raw_data(data), i32(len(data)), DEFAULT_FONT_SIZE, raw_data(glyph_codepoints[:]), GLYPH_COUNT)
		rl.GenTextureMipmaps(&f.texture)
		rl.SetTextureFilter(f.texture, .TRILINEAR)
		register(name, style, f)
	}
	load_font("sans", .Regular, inter_regular)
	load_font("sans", .Bold, inter_bold)
	load_font("sans", .Italic, inter_italic)
	load_font("mono", .Regular, fira_code_regular)
	load_font("mono", .Bold, fira_code_bold)
	load_font("serif", .Regular, noto_serif_regular)
	load_font("serif", .Bold, noto_serif_bold)
	load_font("serif", .Italic, noto_serif_italic)
}
