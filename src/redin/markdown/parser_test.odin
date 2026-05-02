package markdown

import "core:testing"

@(test)
test_plain_text :: proc(t: ^testing.T) {
	blocks := parse("hello world", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[0].text, "hello world")
}

@(test)
test_bold :: proc(t: ^testing.T) {
	blocks := parse("**hi**", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[0].text, "hi")
}

@(test)
test_italic_star :: proc(t: ^testing.T) {
	blocks := parse("*hi*", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Italic)
	testing.expect_value(t, blocks[0].spans[0].text, "hi")
}

@(test)
test_italic_underscore :: proc(t: ^testing.T) {
	blocks := parse("_hi_", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Italic)
	testing.expect_value(t, blocks[0].spans[0].text, "hi")
}

@(test)
test_code :: proc(t: ^testing.T) {
	blocks := parse("`x = 1`", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Code)
	testing.expect_value(t, blocks[0].spans[0].text, "x = 1")
}

@(test)
test_paragraphs :: proc(t: ^testing.T) {
	blocks := parse("first\n\nsecond", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].spans[0].text, "first")
	testing.expect_value(t, blocks[1].spans[0].text, "second")
}

@(test)
test_soft_break :: proc(t: ^testing.T) {
	// Two-space EOL is a soft break — kept as \n inside the span.
	blocks := parse("a  \nb", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].text, "a\nb")
}

@(test)
test_unmatched_delimiter :: proc(t: ^testing.T) {
	blocks := parse("**bold without close", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[0].text, "**bold without close")
}

@(test)
test_nesting_bold_outer_italic_inner :: proc(t: ^testing.T) {
	// With recursive parsing, **outer _inner_** emits two spans:
	// Bold "outer " and Bold_Italic "inner".
	blocks := parse("**outer _inner_**", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 2)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[0].text, "outer ")
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Bold_Italic)
	testing.expect_value(t, blocks[0].spans[1].text, "inner")
}

@(test)
test_mixed :: proc(t: ^testing.T) {
	blocks := parse("**Bold** then `code` then _italic_.", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	// Expected spans: Bold "Bold", Regular " then ", Code "code", Regular " then ", Italic "italic", Regular "."
	testing.expect_value(t, len(blocks[0].spans), 6)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[2].style, Span_Style.Code)
	testing.expect_value(t, blocks[0].spans[3].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[4].style, Span_Style.Italic)
	testing.expect_value(t, blocks[0].spans[5].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[0].text, "Bold")
	testing.expect_value(t, blocks[0].spans[2].text, "code")
	testing.expect_value(t, blocks[0].spans[4].text, "italic")
}

@(test)
test_regular_spans_dont_alias :: proc(t: ^testing.T) {
	// Regression: flush_regular previously returned a slice into a shared
	// builder buffer; subsequent writes after builder_reset reused the same
	// memory, corrupting earlier spans.
	blocks := parse("aaa **B** bbb **C** ccc", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	// Expect: Regular "aaa ", Bold "B", Regular " bbb ", Bold "C", Regular " ccc"
	testing.expect_value(t, len(blocks[0].spans), 5)
	testing.expect_value(t, blocks[0].spans[0].text, "aaa ")
	testing.expect_value(t, blocks[0].spans[1].text, "B")
	testing.expect_value(t, blocks[0].spans[2].text, " bbb ")
	testing.expect_value(t, blocks[0].spans[3].text, "C")
	testing.expect_value(t, blocks[0].spans[4].text, " ccc")
}

@(test)
test_heading_h1 :: proc(t: ^testing.T) {
	blocks := parse("# hello", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading)
	testing.expect_value(t, blocks[0].level, u8(1))
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].text, "hello")
}

@(test)
test_heading_h6 :: proc(t: ^testing.T) {
	blocks := parse("###### six", context.temp_allocator)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading)
	testing.expect_value(t, blocks[0].level, u8(6))
}

@(test)
test_heading_seven_hashes_is_paragraph :: proc(t: ^testing.T) {
	blocks := parse("####### x", context.temp_allocator)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
}

@(test)
test_heading_strips_trailing_hashes :: proc(t: ^testing.T) {
	blocks := parse("## foo ##", context.temp_allocator)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading)
	testing.expect_value(t, blocks[0].level, u8(2))
	testing.expect_value(t, blocks[0].spans[0].text, "foo")
}

@(test)
test_heading_with_inline_bold :: proc(t: ^testing.T) {
	blocks := parse("# **bold** title", context.temp_allocator)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading)
	testing.expect_value(t, blocks[0].level, u8(1))
	testing.expect_value(t, len(blocks[0].spans), 2)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[0].text, "bold")
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[1].text, " title")
}

@(test)
test_heading_no_space_after_hash :: proc(t: ^testing.T) {
	blocks := parse("#foo", context.temp_allocator)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
}

@(test)
test_bold_with_inner_italic :: proc(t: ^testing.T) {
	blocks := parse("**a _b_ c**", context.temp_allocator)
	testing.expect_value(t, len(blocks[0].spans), 3)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[0].text, "a ")
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Bold_Italic)
	testing.expect_value(t, blocks[0].spans[1].text, "b")
	testing.expect_value(t, blocks[0].spans[2].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[2].text, " c")
}

@(test)
test_italic_with_inner_bold :: proc(t: ^testing.T) {
	blocks := parse("_a **b** c_", context.temp_allocator)
	testing.expect_value(t, len(blocks[0].spans), 3)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Italic)
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Bold_Italic)
	testing.expect_value(t, blocks[0].spans[1].text, "b")
	testing.expect_value(t, blocks[0].spans[2].style, Span_Style.Italic)
}

@(test)
test_bold_with_inner_code :: proc(t: ^testing.T) {
	blocks := parse("**a `b` c**", context.temp_allocator)
	testing.expect_value(t, len(blocks[0].spans), 3)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Code)
	testing.expect_value(t, blocks[0].spans[1].text, "b")
	testing.expect_value(t, blocks[0].spans[2].style, Span_Style.Bold)
}
