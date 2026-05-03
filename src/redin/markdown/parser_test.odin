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
	blocks := parse("# Hello", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading_1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].text, "Hello")
}

@(test)
test_heading_h6 :: proc(t: ^testing.T) {
	blocks := parse("###### Hello", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading_6)
}

@(test)
test_heading_with_emphasis :: proc(t: ^testing.T) {
	blocks := parse("## Hello **bold**", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading_2)
	testing.expect_value(t, len(blocks[0].spans), 2)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[1].text, "bold")
}

@(test)
test_heading_too_many_hashes_is_paragraph :: proc(t: ^testing.T) {
	blocks := parse("####### Not a heading", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
}

@(test)
test_heading_no_space_is_paragraph :: proc(t: ^testing.T) {
	blocks := parse("#NotHeading", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
}

@(test)
test_unordered_list_basic :: proc(t: ^testing.T) {
	blocks := parse("- one\n- two", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, blocks[0].ordered, false)
	testing.expect_value(t, len(blocks[0].items), 2)
	testing.expect_value(t, blocks[0].items[0].kind, Block_Kind.List_Item)
	testing.expect_value(t, blocks[0].items[0].spans[0].text, "one")
	testing.expect_value(t, blocks[0].items[1].spans[0].text, "two")
}

@(test)
test_unordered_list_star_marker :: proc(t: ^testing.T) {
	blocks := parse("* a\n* b", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, blocks[0].ordered, false)
	testing.expect_value(t, len(blocks[0].items), 2)
}

@(test)
test_ordered_list_basic :: proc(t: ^testing.T) {
	blocks := parse("1. first\n2. second", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, blocks[0].ordered, true)
	testing.expect_value(t, len(blocks[0].items), 2)
	testing.expect_value(t, blocks[0].items[0].marker, "1.")
	testing.expect_value(t, blocks[0].items[1].marker, "2.")
}

@(test)
test_list_item_inline_emphasis :: proc(t: ^testing.T) {
	blocks := parse("- foo **bold**", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, len(blocks[0].items), 1)
	testing.expect_value(t, len(blocks[0].items[0].spans), 2)
	testing.expect_value(t, blocks[0].items[0].spans[1].style, Span_Style.Bold)
}

@(test)
test_paragraph_after_list :: proc(t: ^testing.T) {
	blocks := parse("- one\n\nThen a paragraph.", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, blocks[1].kind, Block_Kind.Paragraph)
}

@(test)
test_indented_dash_is_paragraph :: proc(t: ^testing.T) {
	// v1 strict: list markers must be at column 0. Indented dash is
	// paragraph text.
	blocks := parse("  - indented", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
}
