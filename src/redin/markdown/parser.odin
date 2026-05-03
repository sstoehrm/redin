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

// Parse markdown source into a list of paragraph blocks. Each block holds
// inline spans (Regular / Bold / Italic / Code). Allocations come from
// the supplied allocator.
parse :: proc(src: string, allocator := context.allocator) -> []Block {
	context.allocator = allocator

	blocks: [dynamic]Block
	paragraphs := split_paragraphs(src)
	for p in paragraphs {
		level, content_start := detect_heading(p)
		if level > 0 {
			spans := parse_inline(p[content_start:])
			kind: Block_Kind
			switch level {
			case 1: kind = .Heading_1
			case 2: kind = .Heading_2
			case 3: kind = .Heading_3
			case 4: kind = .Heading_4
			case 5: kind = .Heading_5
			case 6: kind = .Heading_6
			}
			append(&blocks, Block{kind = kind, spans = spans})
			continue
		}
		// List.
		first_kind, _, _ := detect_list_item(first_line(p))
		if first_kind != 0 {
			items: [dynamic]Block
			ordered := first_kind == 2
			lines := split_lines(p)
			for line in lines {
				k, _, cs := detect_list_item(line)
				if k == 0 {
					// v1 strict: stray non-marker line inside a list — skip.
					continue
				}
				marker_str: string
				if k == 1 {
					marker_str = "•"
				} else {
					// Take the literal numeric marker including the dot.
					m_end := 0
					for m_end < len(line) && line[m_end] >= '0' && line[m_end] <= '9' do m_end += 1
					marker_str = strings.clone(line[:m_end+1])
				}
				spans := parse_inline(line[cs:])
				append(&items, Block{
					kind   = .List_Item,
					spans  = spans,
					marker = marker_str,
				})
			}
			append(&blocks, Block{
				kind    = .List_Group,
				items   = items[:],
				ordered = ordered,
			})
			continue
		}
		spans := parse_inline(p)
		append(&blocks, Block{kind = .Paragraph, spans = spans})
	}
	return blocks[:]
}

split_paragraphs :: proc(src: string) -> []string {
	out: [dynamic]string
	start := 0
	i := 0
	for i < len(src) {
		if src[i] == '\n' {
			j := i + 1
			if j < len(src) && src[j] == '\r' do j += 1
			if j < len(src) && src[j] == '\n' {
				if i > start {
					append(&out, src[start:i])
				}
				k := j + 1
				for k < len(src) && (src[k] == '\n' || src[k] == '\r') do k += 1
				start = k
				i = k
				continue
			}
		}
		i += 1
	}
	if start < len(src) {
		append(&out, src[start:])
	}
	return out[:]
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
		// `*...*` or `_..._` italic.
		if c == '*' || c == '_' {
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

first_line :: proc(s: string) -> string {
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' do return s[:i]
	}
	return s
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
// `*`, skip past `**` (which is bold). For backtick, take the next backtick.
find_close_single :: proc(s: string, from: int, delim: u8) -> int {
	i := from
	for i < len(s) {
		if s[i] == delim {
			if delim == '*' && i + 1 < len(s) && s[i+1] == '*' {
				i += 2
				continue
			}
			return i
		}
		i += 1
	}
	return -1
}
