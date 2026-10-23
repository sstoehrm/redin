package font

import "core:fmt"
import "core:slice"
import "core:testing"
import rl "vendor:raylib"

// Review C3: the shared glyph set. These tests need no GL context —
// rl.LoadFontData only rasterises glyphs on the CPU.

@(test)
test_glyph_codepoints_cover_decided_ranges :: proc(t: ^testing.T) {
	testing.expect_value(t, GLYPH_COUNT, 95 + 224 + 17)
	cps := glyph_codepoints[:]
	testing.expect(t, slice.is_sorted(cps), "codepoints are ascending (and so unique)")
	for i in 1 ..< len(cps) {
		testing.expect(t, cps[i] != cps[i-1], "no duplicate codepoints")
	}
	for cp in ([]rune{' ', '~', 0xA0, 0xFC, 0xDF, 0x17F, 0x2014, 0x20AC, 0x2122}) {
		_, found := slice.binary_search(cps, cp)
		testing.expectf(t, found, "U+%04X is in the glyph set", cp)
	}
	for cp in ([]rune{0x1F, 0x7F, 0x9F, 0x180, 0x3A9}) {
		_, found := slice.binary_search(cps, cp)
		testing.expectf(t, !found, "U+%04X is outside the glyph set", cp)
	}
}

// Which of the shared glyph set's codepoints each bundled font actually
// provides. raylib drops codepoints the font has no glyph for (they then
// render as '?'), so this pins the known gaps: a font update that loses
// coverage, or a glyph-set change, shows up here.
@(test)
test_embedded_fonts_glyph_coverage :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		data:    []u8,
		missing: []rune,
	}
	// Inter has no U+00AD (soft hyphen) or U+0149 (deprecated ŉ); Fira
	// Code has no U+017F (long s). All three are rare; they render as '?'.
	inter_gaps := []rune{0xAD, 0x149}
	fira_gaps := []rune{0x17F}
	cases := []Case{
		{"Inter-Regular",      inter_regular,      inter_gaps},
		{"Inter-Bold",         inter_bold,         inter_gaps},
		{"Inter-Italic",       inter_italic,       inter_gaps},
		{"FiraCode-Regular",   fira_code_regular,  fira_gaps},
		{"FiraCode-Bold",      fira_code_bold,     fira_gaps},
		{"NotoSerif-Regular",  noto_serif_regular, nil},
		{"NotoSerif-Bold",     noto_serif_bold,    nil},
		{"NotoSerif-Italic",   noto_serif_italic,  nil},
	}
	for c in cases {
		count: i32
		glyphs := rl.LoadFontData(
			raw_data(c.data), i32(len(c.data)), DEFAULT_FONT_SIZE,
			raw_data(glyph_codepoints[:]), GLYPH_COUNT, .DEFAULT, &count)
		testing.expectf(t, glyphs != nil, "%s: LoadFontData returned glyphs", c.name)
		if glyphs == nil do continue
		defer rl.UnloadFontData(glyphs, count)

		present := make(map[rune]bool, context.temp_allocator)
		for g in glyphs[:count] do present[g.value] = true
		missing: [dynamic]rune
		missing.allocator = context.temp_allocator
		for cp in glyph_codepoints do if !present[cp] do append(&missing, cp)
		testing.expectf(t, slice.equal(missing[:], c.missing),
			"%s: missing codepoints %v, expected %v", c.name,
			fmt_runes(missing[:]), fmt_runes(c.missing))
	}
}

@(private = "file")
fmt_runes :: proc(rs: []rune) -> string {
	out: [dynamic]string
	out.allocator = context.temp_allocator
	for r in rs do append(&out, fmt.tprintf("U+%04X", r))
	return fmt.tprintf("%v", out[:])
}
