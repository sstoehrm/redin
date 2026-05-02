package markdown

import "core:strings"

Span_Style :: enum u8 { Regular, Bold, Italic, Bold_Italic, Code }

Span :: struct {
	style: Span_Style,
	text:  string,
}

Block_Kind :: enum u8 { Paragraph, Heading }

Block :: struct {
	kind:  Block_Kind,
	level: u8,        // 1..6 for Heading; 0 for Paragraph
	spans: []Span,
}

// Parse markdown source into a list of blocks. Each block holds inline spans
// (Regular / Bold / Italic / Code). Allocations come from the supplied allocator.
parse :: proc(src: string, allocator := context.allocator) -> []Block {
	context.allocator = allocator

	blocks: [dynamic]Block
	paragraphs := split_paragraphs(src)
	for p in paragraphs {
		if level, body, is_h := detect_heading(p); is_h {
			spans := parse_inline(body)
			append(&blocks, Block{kind = .Heading, level = level, spans = spans})
		} else {
			spans := parse_inline(p)
			append(&blocks, Block{kind = .Paragraph, spans = spans})
		}
	}
	return blocks[:]
}

// Returns (level, trimmed-body, true) if `p` opens with 1..6 `#` followed
// by a space. Trailing `#` runs and surrounding whitespace are stripped.
detect_heading :: proc(p: string) -> (level: u8, body: string, ok: bool) {
	i := 0
	for i < len(p) && p[i] == '#' do i += 1
	if i == 0 || i > 6 do return 0, "", false
	if i >= len(p) || p[i] != ' ' do return 0, "", false
	rest := p[i + 1:]
	// Trim leading whitespace.
	start := 0
	for start < len(rest) && (rest[start] == ' ' || rest[start] == '\t') do start += 1
	// Trim trailing whitespace + a closing run of `#`s + the space before it.
	end := len(rest)
	for end > start && (rest[end - 1] == ' ' || rest[end - 1] == '\t') do end -= 1
	for end > start && rest[end - 1] == '#' do end -= 1
	for end > start && (rest[end - 1] == ' ' || rest[end - 1] == '\t') do end -= 1
	return u8(i), rest[start:end], true
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
	parse_inline_into(&out, pre, .Regular)
	return out[:]
}

// Walk `text` emitting spans into `out`, merging each emitted span's style
// with `outer` per the merge table in the spec. Recurses on emphasis bodies.
parse_inline_into :: proc(out: ^[dynamic]Span, text: string, outer: Span_Style) {
	current := strings.builder_make()
	defer strings.builder_destroy(&current)
	i := 0

	flush_regular :: proc(out: ^[dynamic]Span, b: ^strings.Builder, outer: Span_Style) {
		if strings.builder_len(b^) > 0 {
			cloned := strings.clone(strings.to_string(b^))
			append(out, Span{style = outer, text = cloned})
			strings.builder_reset(b)
		}
	}

	for i < len(text) {
		c := text[i]
		// `**...**` greedy bold.
		if c == '*' && i + 1 < len(text) && text[i + 1] == '*' {
			if close_idx := find_close_double(text, i + 2, '*'); close_idx >= 0 {
				flush_regular(out, &current, outer)
				inner := text[i + 2:close_idx]
				parse_inline_into(out, inner, merge_style(outer, .Bold))
				i = close_idx + 2
				continue
			}
			strings.write_byte(&current, '*')
			strings.write_byte(&current, '*')
			i += 2
			continue
		}
		// `*…*` / `_…_` italic.
		if c == '*' || c == '_' {
			if close_idx := find_close_single(text, i + 1, c); close_idx >= 0 {
				flush_regular(out, &current, outer)
				inner := text[i + 1:close_idx]
				parse_inline_into(out, inner, merge_style(outer, .Italic))
				i = close_idx + 1
				continue
			}
		}
		// Backtick code (leaf).
		if c == '`' {
			if close_idx := find_close_single(text, i + 1, '`'); close_idx >= 0 {
				flush_regular(out, &current, outer)
				inner := text[i + 1:close_idx]
				cloned := strings.clone(inner)
				append(out, Span{style = .Code, text = cloned})
				i = close_idx + 1
				continue
			}
		}
		strings.write_byte(&current, c)
		i += 1
	}
	flush_regular(out, &current, outer)
}

// Combine outer + inner per the table in the spec.
// Code always wins. Bold_Italic absorbs further Bold/Italic.
merge_style :: proc(outer, inner: Span_Style) -> Span_Style {
	if inner == .Code do return .Code
	if outer == .Regular do return inner
	if inner == .Regular do return outer
	if outer == inner do return outer
	if outer == .Bold_Italic do return .Bold_Italic
	if inner == .Bold_Italic do return .Bold_Italic
	// Bold ⊕ Italic (in either order) → Bold_Italic.
	if (outer == .Bold && inner == .Italic) || (outer == .Italic && inner == .Bold) {
		return .Bold_Italic
	}
	return inner
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
