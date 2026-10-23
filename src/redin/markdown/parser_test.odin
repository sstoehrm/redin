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

// ---------------------------------------------------------------------------
// Review C10: content must never be dropped or merged across block kinds.
// ---------------------------------------------------------------------------

@(test)
test_non_list_line_ends_list :: proc(t: ^testing.T) {
	blocks := parse("- one\n- two\nClosing remark", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, len(blocks[0].items), 2)
	testing.expect_value(t, blocks[0].items[1].spans[0].text, "two")
	testing.expect_value(t, blocks[1].kind, Block_Kind.Paragraph)
	testing.expect_value(t, blocks[1].spans[0].text, "Closing remark")
}

@(test)
test_indented_continuation_joins_list_item :: proc(t: ^testing.T) {
	blocks := parse("- item\n  continuation\n- next", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, len(blocks[0].items), 2)
	testing.expect_value(t, len(blocks[0].items[0].spans), 1)
	testing.expect_value(t, blocks[0].items[0].spans[0].text, "item continuation")
	testing.expect_value(t, blocks[0].items[1].spans[0].text, "next")
}

@(test)
test_heading_ends_at_end_of_line :: proc(t: ^testing.T) {
	blocks := parse("# Title\nBody", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading_1)
	testing.expect_value(t, blocks[0].spans[0].text, "Title")
	testing.expect_value(t, blocks[1].kind, Block_Kind.Paragraph)
	testing.expect_value(t, blocks[1].spans[0].text, "Body")
}

@(test)
test_heading_interrupts_paragraph :: proc(t: ^testing.T) {
	blocks := parse("Body\n## Next", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
	testing.expect_value(t, blocks[0].spans[0].text, "Body")
	testing.expect_value(t, blocks[1].kind, Block_Kind.Heading_2)
	testing.expect_value(t, blocks[1].spans[0].text, "Next")
}

@(test)
test_list_without_preceding_blank_line :: proc(t: ^testing.T) {
	blocks := parse("Intro:\n- a\n- b", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
	testing.expect_value(t, blocks[0].spans[0].text, "Intro:")
	testing.expect_value(t, blocks[1].kind, Block_Kind.List_Group)
	testing.expect_value(t, len(blocks[1].items), 2)
	testing.expect_value(t, blocks[1].items[0].spans[0].text, "a")
	testing.expect_value(t, blocks[1].items[1].spans[0].text, "b")
}

@(test)
test_list_marker_kind_change_starts_new_list :: proc(t: ^testing.T) {
	blocks := parse("- a\n1. b", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Group)
	testing.expect_value(t, blocks[0].ordered, false)
	testing.expect_value(t, blocks[1].kind, Block_Kind.List_Group)
	testing.expect_value(t, blocks[1].ordered, true)
	testing.expect_value(t, blocks[1].items[0].marker, "1.")
}

@(test)
test_whitespace_only_line_separates_paragraphs :: proc(t: ^testing.T) {
	blocks := parse("first\n   \nsecond", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].spans[0].text, "first")
	testing.expect_value(t, blocks[1].spans[0].text, "second")
}

@(test)
test_underscore_intraword_is_literal :: proc(t: ^testing.T) {
	blocks := parse("call snake_case_name now", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[0].text, "call snake_case_name now")
}

@(test)
test_underscore_dunder_is_literal :: proc(t: ^testing.T) {
	blocks := parse("see __init__ here", context.temp_allocator)
	testing.expect_value(t, len(blocks[0].spans), 1)
	testing.expect_value(t, blocks[0].spans[0].text, "see __init__ here")
}

@(test)
test_underscore_italic_between_words :: proc(t: ^testing.T) {
	blocks := parse("foo _bar_ baz", context.temp_allocator)
	testing.expect_value(t, len(blocks[0].spans), 3)
	testing.expect_value(t, blocks[0].spans[0].text, "foo ")
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Italic)
	testing.expect_value(t, blocks[0].spans[1].text, "bar")
	testing.expect_value(t, blocks[0].spans[2].text, " baz")
}

@(test)
test_underscore_italic_may_contain_intraword_underscore :: proc(t: ^testing.T) {
	blocks := parse("(_foo_bar_)", context.temp_allocator)
	testing.expect_value(t, len(blocks[0].spans), 3)
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Italic)
	testing.expect_value(t, blocks[0].spans[1].text, "foo_bar")
}

@(test)
test_star_intraword_italic_unchanged :: proc(t: ^testing.T) {
	blocks := parse("a*b*c", context.temp_allocator)
	testing.expect_value(t, len(blocks[0].spans), 3)
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Italic)
	testing.expect_value(t, blocks[0].spans[1].text, "b")
}

@(test)
test_crlf_normalised :: proc(t: ^testing.T) {
	blocks := parse("# T\r\nline one\r\nline two\r\n\r\n- a\r\n- b\r\n", context.temp_allocator)
	testing.expect_value(t, len(blocks), 3)
	testing.expect_value(t, blocks[0].spans[0].text, "T")
	testing.expect_value(t, blocks[1].spans[0].text, "line one line two")
	testing.expect_value(t, blocks[2].kind, Block_Kind.List_Group)
	testing.expect_value(t, blocks[2].items[0].spans[0].text, "a")
	testing.expect_value(t, blocks[2].items[1].spans[0].text, "b")
}

@(test)
test_lone_cr_normalised :: proc(t: ^testing.T) {
	blocks := parse("a\r\rb", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].spans[0].text, "a")
	testing.expect_value(t, blocks[1].spans[0].text, "b")
}

@(test)
test_crlf_soft_break :: proc(t: ^testing.T) {
	blocks := parse("a  \r\nb", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].spans[0].text, "a\nb")
}
