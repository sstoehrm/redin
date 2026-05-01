package markdown

import "core:strings"

Span_Style :: enum u8 { Regular, Bold, Italic, Code }

Span :: struct {
	style: Span_Style,
	text:  string,
}

Block_Kind :: enum u8 { Paragraph }

Block :: struct {
	kind:  Block_Kind,
	spans: []Span,
}

// Parse markdown source into a list of paragraph blocks. Each block holds
// inline spans (Regular / Bold / Italic / Code). Allocations come from
// the supplied allocator.
parse :: proc(src: string, allocator := context.allocator) -> []Block {
	context.allocator = allocator

	blocks: [dynamic]Block
	paragraphs := split_paragraphs(src)
	for p in paragraphs {
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
			append(out, Span{style = .Regular, text = strings.to_string(b^)})
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
