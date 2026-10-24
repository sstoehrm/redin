package markdown

import "core:strings"
import text_pkg "../text"

Span :: text_pkg.Span
Span_Style :: text_pkg.Span_Style

Block_Kind :: enum u8 {
	Paragraph,
	Heading_1, Heading_2, Heading_3, Heading_4, Heading_5, Heading_6,
	List_Item,
	List_Group,
}

Block :: struct {
	kind:    Block_Kind,
	spans:   []Span,    // Paragraph / Heading_N / List_Item: inline content
	items:   []Block,   // List_Group only: child List_Items in source order
	ordered: bool,      // List_Group only: true for "1." markers, false for "-"/"*"
	marker:  string,    // List_Item only: the literal marker text ("•" / "1." / etc.)
}

// Parse markdown source into a list of blocks. Each block holds inline
// spans (Regular / Bold / Italic / Code). Allocations come from the
// supplied allocator.
//
// Block rules (line-driven, review C10):
//   - CRLF and lone CR are normalised to LF first.
//   - A blank (empty or whitespace-only) line ends the current block.
//   - An ATX heading (`#`..`######` + space, column 0) is exactly one
//     line; it ends any open paragraph or list.
//   - A list marker at column 0 (`- `, `* `, `<digits>. `) starts or
//     continues a list without needing a preceding blank line. A marker of
//     the other kind (ordered vs unordered) starts a new list.
//   - Inside a list, an indented line (leading space/tab) continues the
//     current item; any other line ends the list and starts a paragraph.
//   - Remaining lines accumulate into the current paragraph.
parse :: proc(src: string, allocator := context.allocator) -> []Block {
	context.allocator = allocator

	blocks: [dynamic]Block
	normalised := normalise_newlines(src)

	Open :: enum u8 { None, Paragraph, List }
	open: Open = .None
	para_lines: [dynamic]string
	items: [dynamic]Block
	item_lines: [dynamic]string
	item_marker: string
	list_ordered := false

	flush_item :: proc(items: ^[dynamic]Block, item_lines: ^[dynamic]string, marker: string) {
		if len(item_lines^) == 0 do return
		joined := strings.join(item_lines[:], "\n")
		append(items, Block{
			kind   = .List_Item,
			spans  = parse_inline(joined),
			marker = marker,
		})
		clear(item_lines)
	}

	close_open :: proc(
		open: ^Open,
		blocks: ^[dynamic]Block,
		para_lines: ^[dynamic]string,
		items: ^[dynamic]Block,
		item_lines: ^[dynamic]string,
		item_marker: string,
		list_ordered: bool,
	) {
		switch open^ {
		case .None:
		case .Paragraph:
			joined := strings.join(para_lines[:], "\n")
			append(blocks, Block{kind = .Paragraph, spans = parse_inline(joined)})
			clear(para_lines)
		case .List:
			flush_item(items, item_lines, item_marker)
			append(blocks, Block{
				kind    = .List_Group,
				items   = items[:],
				ordered = list_ordered,
			})
			// The group now owns the backing array; start a fresh one.
			items^ = {}
		}
		open^ = .None
	}

	for line in split_lines(normalised) {
		if is_blank(line) {
			close_open(&open, &blocks, &para_lines, &items, &item_lines, item_marker, list_ordered)
			continue
		}

		if level, content_start := detect_heading(line); level > 0 {
			close_open(&open, &blocks, &para_lines, &items, &item_lines, item_marker, list_ordered)
			kind: Block_Kind
			switch level {
			case 1: kind = .Heading_1
			case 2: kind = .Heading_2
			case 3: kind = .Heading_3
			case 4: kind = .Heading_4
			case 5: kind = .Heading_5
			case 6: kind = .Heading_6
			}
			append(&blocks, Block{kind = kind, spans = parse_inline(line[content_start:])})
			continue
		}

		if k, ordered, cs := detect_list_item(line); k != 0 {
			if open == .List && ordered == list_ordered {
				flush_item(&items, &item_lines, item_marker)
			} else {
				close_open(&open, &blocks, &para_lines, &items, &item_lines, item_marker, list_ordered)
				open = .List
				list_ordered = ordered
			}
			if k == 1 {
				item_marker = "•"
			} else {
				// Take the literal numeric marker including the dot.
				item_marker = strings.clone(line[:cs - 1])
			}
			append(&item_lines, line[cs:])
			continue
		}

		if open == .List {
			if line[0] == ' ' || line[0] == '\t' {
				// Indented continuation of the current list item.
				append(&item_lines, strings.trim_left(line, " \t"))
				continue
			}
			// A non-indented, non-marker line ends the list.
			close_open(&open, &blocks, &para_lines, &items, &item_lines, item_marker, list_ordered)
		}

		open = .Paragraph
		append(&para_lines, line)
	}
	close_open(&open, &blocks, &para_lines, &items, &item_lines, item_marker, list_ordered)
	return blocks[:]
}

// Rewrite CRLF and lone CR line endings to LF so every later stage only
// has to deal with '\n'. Returns `src` unchanged when it has no '\r'.
normalise_newlines :: proc(src: string) -> string {
	if !strings.contains_rune(src, '\r') do return src
	b := strings.builder_make_len_cap(0, len(src))
	for i := 0; i < len(src); i += 1 {
		c := src[i]
		if c == '\r' {
			strings.write_byte(&b, '\n')
			if i + 1 < len(src) && src[i+1] == '\n' do i += 1
			continue
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

is_blank :: proc(line: string) -> bool {
	for i := 0; i < len(line); i += 1 {
		if line[i] != ' ' && line[i] != '\t' do return false
	}
	return true
}

// Replace "  \n" (two-space soft break) with "\n", drop other \n
// (single newlines collapse to space — markdown convention).
process_soft_breaks :: proc(s: string) -> string {
	if !strings.contains(s, "\n") {
		return s
	}
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if i + 2 < len(s) && s[i] == ' ' && s[i+1] == ' ' && s[i+2] == '\n' {
			strings.write_byte(&b, '\n')
			i += 3
			continue
		}
		if s[i] == '\n' {
			strings.write_byte(&b, ' ')
			i += 1
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

parse_inline :: proc(src: string) -> []Span {
	pre := process_soft_breaks(src)
	out: [dynamic]Span
	current := strings.builder_make()
	i := 0

	flush_regular :: proc(out: ^[dynamic]Span, b: ^strings.Builder) {
		if strings.builder_len(b^) > 0 {
			cloned := strings.clone(strings.to_string(b^))
			append(out, Span{style = .Regular, text = cloned})
			strings.builder_reset(b)
		}
	}

	for i < len(pre) {
		c := pre[i]
		// `**...**` first (greedy).
		if c == '*' && i + 1 < len(pre) && pre[i+1] == '*' {
			if close_idx := find_close_double(pre, i + 2, '*'); close_idx >= 0 {
				flush_regular(&out, &current)
				append(&out, Span{style = .Bold, text = pre[i+2:close_idx]})
				i = close_idx + 2
				continue
			}
			// Bold delimiter unmatched — emit both stars as literal text.
			strings.write_byte(&current, '*')
			strings.write_byte(&current, '*')
			i += 2
			continue
		}
		// `*...*` or `_..._` italic. `_` only opens at a word start
		// (intraword rule, review C10), so `snake_case_name` stays literal.
		if c == '*' || (c == '_' && underscore_can_open(pre, i)) {
			if close_idx := find_close_single(pre, i + 1, c); close_idx >= 0 {
				flush_regular(&out, &current)
				append(&out, Span{style = .Italic, text = pre[i+1:close_idx]})
				i = close_idx + 1
				continue
			}
		}
		// Backtick code.
		if c == '`' {
			if close_idx := find_close_single(pre, i + 1, '`'); close_idx >= 0 {
				flush_regular(&out, &current)
				append(&out, Span{style = .Code, text = pre[i+1:close_idx]})
				i = close_idx + 1
				continue
			}
		}
		strings.write_byte(&current, c)
		i += 1
	}
	flush_regular(&out, &current)
	return out[:]
}

// detect_list_item returns (kind, ordered, content_start) where:
//   kind == 0: not a list item
//   kind == 1: unordered ("- " or "* ")
//   kind == 2: ordered ("<digit>+. ")
// ordered is meaningful when kind != 0. content_start is the byte
// index after the marker and the required single space.
detect_list_item :: proc(s: string) -> (kind: int, ordered: bool, content_start: int) {
	if len(s) == 0 do return 0, false, 0
	if s[0] == '-' || s[0] == '*' {
		if len(s) < 2 || s[1] != ' ' do return 0, false, 0
		return 1, false, 2
	}
	// Ordered: one or more digits, then '.', then ' '.
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
	if i == 0 do return 0, false, 0
	if i+1 >= len(s) do return 0, false, 0
	if s[i] != '.' || s[i+1] != ' ' do return 0, false, 0
	return 2, true, i + 2
}

split_lines :: proc(s: string) -> []string {
	out: [dynamic]string
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			append(&out, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) do append(&out, s[start:])
	return out[:]
}

// detect_heading returns (level, content_start) where level is
// 1..6 for `# `..`###### ` and 0 for non-heading. content_start is
// the byte index after the leading `#`s and the required single space.
detect_heading :: proc(s: string) -> (level: int, content_start: int) {
	i := 0
	for i < len(s) && s[i] == '#' do i += 1
	if i == 0 || i > 6 do return 0, 0
	if i >= len(s) || s[i] != ' ' do return 0, 0
	return i, i + 1
}

// Find the next occurrence of two consecutive `delim` chars at or after `from`.
find_close_double :: proc(s: string, from: int, delim: u8) -> int {
	i := from
	for i + 1 < len(s) {
		if s[i] == delim && s[i+1] == delim do return i
		i += 1
	}
	return -1
}

// Find the next single occurrence of `delim` at or after `from`. For italic
// `*`, skip past `**` (which is bold). For `_`, only a delimiter at a word
// end closes (see underscore_can_close). For backtick, take the next one.
find_close_single :: proc(s: string, from: int, delim: u8) -> int {
	i := from
	for i < len(s) {
		if s[i] == delim {
			if delim == '*' && i + 1 < len(s) && s[i+1] == '*' {
				i += 2
				continue
			}
			if delim == '_' && !underscore_can_close(s, i) {
				i += 1
				continue
			}
			return i
		}
		i += 1
	}
	return -1
}

// Word characters for the `_` intraword rule: ASCII letters/digits, `_`
// itself, and any non-ASCII byte (so UTF-8 letters count as word chars).
// Counting `_` as a word char keeps runs like `__init__` literal, since
// v1 has no `__bold__`.
@(private)
is_word_byte :: proc(c: u8) -> bool {
	switch c {
	case 'a'..='z', 'A'..='Z', '0'..='9', '_':
		return true
	}
	return c >= 0x80
}

@(private)
is_space_byte :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n'
}

// A `_` opens emphasis only when it is not preceded by a word character
// and is followed by a non-space, non-`_` character (CommonMark-like).
underscore_can_open :: proc(s: string, i: int) -> bool {
	if i > 0 && is_word_byte(s[i-1]) do return false
	if i + 1 >= len(s) do return false
	n := s[i+1]
	return !is_space_byte(n) && n != '_'
}

// A `_` closes emphasis only when it is not followed by a word character
// and is preceded by a non-space, non-`_` character.
underscore_can_close :: proc(s: string, i: int) -> bool {
	if i + 1 < len(s) && is_word_byte(s[i+1]) do return false
	if i == 0 do return false
	p := s[i-1]
	return !is_space_byte(p) && p != '_'
}
