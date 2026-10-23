package text

import "core:testing"
import rl "vendor:raylib"
import "../font"

// Review C3: with the shared glyph set loaded, measurement, wrapping and
// caret mapping must use the real advance of multi-byte characters
// rather than the '?' fallback's. Tests have no GL context, so build a
// CPU-only rl.Font: glyph data from rl.LoadFontData plus zeroed recs and
// a dummy texture id, which is all raylib's IsFontValid gate checks.
// GetGlyphIndex / MeasureTextEx then read only the glyph table. Never
// pass it to UnloadFont or a draw call — free it with free_cpu_font.

@(private = "file")
cpu_font :: proc() -> rl.Font {
	count: i32
	glyphs := rl.LoadFontData(
		raw_data(font.inter_regular), i32(len(font.inter_regular)), font.DEFAULT_FONT_SIZE,
		raw_data(font.glyph_codepoints[:]), font.GLYPH_COUNT, .DEFAULT, &count)
	recs := make([]rl.Rectangle, count)
	return rl.Font{
		baseSize   = font.DEFAULT_FONT_SIZE,
		glyphCount = count,
		glyphs     = glyphs,
		recs       = raw_data(recs),
		texture    = {id = 1}, // dummy: satisfies IsFontValid, never bound
	}
}

@(private = "file")
free_cpu_font :: proc(f: rl.Font) {
	rl.UnloadFontData(f.glyphs, f.glyphCount)
	delete(f.recs[:f.glyphCount])
}

@(test)
test_multibyte_glyphs_measure_with_their_own_advance :: proc(t: ^testing.T) {
	f := cpu_font()
	testing.expect(t, f.glyphs != nil, "font data loaded")
	if f.glyphs == nil do return
	defer free_cpu_font(f)

	q := rl.GetGlyphIndex(f, '?')
	testing.expect(t, rl.GetGlyphIndex(f, 'ü') != q, "ü has its own glyph")
	testing.expect(t, rl.GetGlyphIndex(f, '€') != q, "€ has its own glyph")
	testing.expect(t, rl.GetGlyphIndex(f, 'Ω') == q, "Ω (outside the set) falls back to '?'")

	// Inter's 'ü' shares 'u's advance; '?' is narrower. Measured widths
	// of the same-length strings must follow the real glyphs.
	w_u  := measure_range("uuuu", 0, 4, f, 64, 0)
	w_ue := measure_range("üüüü", 0, len("üüüü"), f, 64, 0)
	w_q  := measure_range("????", 0, 4, f, 64, 0)
	testing.expect_value(t, w_ue, w_u)
	testing.expect(t, w_ue != w_q, "ü is not measured with the '?' advance")

	// compute_lines' running advance agrees with MeasureTextEx.
	lines := compute_lines("üüüü", f, 64, 0, 0)
	defer delete(lines)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0].width, w_ue)

	// Wrapping at the width of two ü's breaks "üü üü" at the space.
	two := measure_range("üü", 0, len("üü"), f, 64, 0)
	wrapped := compute_lines("üü üü", f, 64, 0, two + 1)
	defer delete(wrapped)
	testing.expect_value(t, len(wrapped), 2)
	testing.expect_value(t, wrapped[0].end, len("üü"))
	testing.expect_value(t, wrapped[1].start, len("üü "))

	// Caret mapping lands on codepoint boundaries (2-byte steps for ü).
	one := measure_range("ü", 0, len("ü"), f, 64, 0)
	testing.expect_value(t, offset_at_x("üüüü", 0, len("üüüü"), one * 1.1, f, 64, 0), 2)
	testing.expect_value(t, offset_at_x("üüüü", 0, len("üüüü"), one * 2.9, f, 64, 0), 6)
}
