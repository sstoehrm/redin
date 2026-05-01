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
test_no_nesting_v1 :: proc(t: ^testing.T) {
	blocks := parse("**outer _inner_**", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[0].text, "outer _inner_")
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
