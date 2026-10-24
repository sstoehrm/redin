package font

import "core:strings"
import rl "vendor:raylib"

// Glyph set baked into every font atlas — the bundled fonts and theme
// `:font-face` fonts alike (review C3). raylib's default when no
// codepoint list is given is ASCII 32..126 only, which rendered every
// other character (ü, é, ß, €, —, …) as '?'. Codepoints outside this set
// still fall back to '?' (raylib's GetGlyphIndex behaviour).
//
//   U+0020–U+007E  Basic Latin (printable ASCII)
//   U+00A0–U+00FF  Latin-1 Supplement
//   U+0100–U+017F  Latin Extended-A
//   plus common punctuation / symbols:
//   – — ‘ ’ ‚ “ ” „ † ‡ • … ‰ ‹ › € ™
//
// Keep docs/reference/theme.md ("Glyph coverage") in sync.

@(private = "file")
EXTRA_CODEPOINTS :: [?]rune{
	0x2013, // – en dash
	0x2014, // — em dash
	0x2018, // ‘
	0x2019, // ’
	0x201A, // ‚
	0x201C, // “
	0x201D, // ”
	0x201E, // „
	0x2020, // †
	0x2021, // ‡
	0x2022, // • bullet
	0x2026, // … ellipsis
	0x2030, // ‰
	0x2039, // ‹
	0x203A, // ›
	0x20AC, // € euro
	0x2122, // ™
}

GLYPH_COUNT :: (0x7E - 0x20 + 1) + (0x17F - 0xA0 + 1) + len(EXTRA_CODEPOINTS)

// Built once at package init; shared (read-only) by every load site.
glyph_codepoints: [GLYPH_COUNT]rune

@(init, private = "file")
build_glyph_codepoints :: proc "contextless" () {
	n := 0
	for cp in rune(0x20) ..= 0x7E {
		glyph_codepoints[n] = cp
		n += 1
	}
	for cp in rune(0xA0) ..= 0x17F {
		glyph_codepoints[n] = cp
		n += 1
	}
	extra := EXTRA_CODEPOINTS
	for cp in extra {
		glyph_codepoints[n] = cp
		n += 1
	}
}

// raylib's own LoadFont default for TTF/OTF (FONT_TTF_DEFAULT_SIZE).
// Theme font-face fonts keep this atlas size so switching from
// rl.LoadFont to rl.LoadFontEx changes only the glyph set.
FONT_FACE_BASE_SIZE :: 32

// Load a theme font-face file with the shared glyph set. TTF/OTF go
// through LoadFontEx with glyph_codepoints; any other format (.fnt
// BMFont, image fonts) defines its own glyphs and still uses LoadFont.
// Mirrors LoadFont's point filter so only the glyph set changes.
load_file :: proc(path: cstring) -> rl.Font {
	lower := strings.to_lower(string(path), context.temp_allocator)
	if strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf") {
		f := rl.LoadFontEx(path, FONT_FACE_BASE_SIZE, raw_data(glyph_codepoints[:]), GLYPH_COUNT)
		if f.texture.id > 0 do rl.SetTextureFilter(f.texture, .POINT)
		return f
	}
	return rl.LoadFont(path)
}
