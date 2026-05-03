# Markdown Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `:markdown true` attribute to `:text` nodes so inline markdown (bold / italic / inline code / paragraph + soft line breaks) renders inline with proper font styling.

**Architecture:** A new `src/redin/markdown/` package with a single-pass parser (`parse(string) -> []Block`), a span-aware word-wrap layout, and a draw step. Plain `:text` is unchanged; `n.markdown == true` dispatches to the markdown path inside `draw_text`. Italic glyphs come from newly-embedded Inter Italic and Noto Serif Italic fonts.

**Tech Stack:** Odin (host + parser + layout), Raylib (DrawTextEx, MeasureTextEx), Fennel (test fixture), Babashka (UI test).

**Spec:** `docs/superpowers/specs/2026-05-01-markdown-rendering-design.md`. Issue: #100.

---

## File Structure

**Created:**
- `src/redin/font/Inter-Italic.ttf` — embedded font (binary, ~150KB).
- `src/redin/font/NotoSerif-Italic.ttf` — embedded font (binary, ~110KB).
- `src/redin/markdown/parser.odin` — types (`Span_Style`, `Span`, `Block_Kind`, `Block`) and `parse()`.
- `src/redin/markdown/parser_test.odin` — 9 unit tests for the parser.
- `src/redin/markdown/render.odin` — `Span_Box`, `Laid_Block`, `layout()`, `draw()`, `free_laid()`.
- `test/ui/markdown_app.fnl` — test fixture exercising every supported markdown feature.
- `test/ui/test_markdown.bb` — UI test asserting attr presence + writing a screenshot artifact.

**Modified:**
- `src/redin/font/embedded.odin` — load the two new italic fonts.
- `src/redin/types/view_tree.odin` — add `markdown: bool` to `NodeText`.
- `src/redin/bridge/bridge.odin` — parse `:markdown` attr in `lua_read_node`'s text case.
- `src/redin/render.odin` — `draw_text` branches to markdown path when `n.markdown`.
- `docs/core-api.md`, `docs/reference/elements.md`, `.claude/skills/redin-dev/SKILL.md` — documentation.

---

## Task 1: Embed italic fonts

**Files:**
- Create: `src/redin/font/Inter-Italic.ttf`
- Create: `src/redin/font/NotoSerif-Italic.ttf`
- Modify: `src/redin/font/embedded.odin`

- [ ] **Step 1: Download the fonts**

```bash
curl -L -o src/redin/font/Inter-Italic.ttf \
  https://github.com/google/fonts/raw/main/ofl/inter/Inter%5Bopsz%2Cwght%5D.ttf || true

# The variable Inter file may not have an italic axis on master — fall back to rsms's release.
# If the previous file is fine but doesn't include italic, use rsms's static italic instead:
curl -L -o src/redin/font/Inter-Italic.ttf \
  https://rsms.me/inter/font-files/Inter-Italic.otf

# Convert OTF → TTF if needed: not strictly required since rl.LoadFontFromMemory accepts
# OTF as well via a different extension hint. Confirm by inspecting the file:
file src/redin/font/Inter-Italic.ttf

curl -L -o src/redin/font/NotoSerif-Italic.ttf \
  https://github.com/google/fonts/raw/main/ofl/notoserif/NotoSerif%5Bwdth%2Cwght%5D-Italic.ttf
file src/redin/font/NotoSerif-Italic.ttf
```

If those URLs return a 404, fall back to:
- Inter Italic: any release at https://github.com/rsms/inter/releases (download the static `Inter-Italic.ttf`).
- Noto Serif Italic: download from Google Fonts at https://fonts.google.com/noto/specimen/Noto+Serif

The end state is: two binary `.ttf` files in `src/redin/font/`, openable by `rl.LoadFontFromMemory` (it handles both TTF and OTF — the existing code uses `".ttf"` as the format hint, which is fine for both formats in raylib).

Verify both files are non-empty TTF/OTF binaries:
```bash
ls -la src/redin/font/*.ttf
file src/redin/font/Inter-Italic.ttf src/redin/font/NotoSerif-Italic.ttf
```

- [ ] **Step 2: Update `embedded.odin`**

Open `src/redin/font/embedded.odin`. Add two `#load`s and two `load_font` calls:

```odin
package font

import rl "vendor:raylib"

inter_regular      := #load("Inter-Regular.ttf")
inter_bold         := #load("Inter-Bold.ttf")
inter_italic       := #load("Inter-Italic.ttf")
fira_code_regular  := #load("FiraCode-Regular.ttf")
fira_code_bold     := #load("FiraCode-Bold.ttf")
noto_serif_regular := #load("NotoSerif-Regular.ttf")
noto_serif_bold    := #load("NotoSerif-Bold.ttf")
noto_serif_italic  := #load("NotoSerif-Italic.ttf")

DEFAULT_FONT_SIZE :: 64

load_embedded :: proc() {
	load_font :: proc(name: string, style: Font_Style, data: []u8) {
		f := rl.LoadFontFromMemory(".ttf", raw_data(data), i32(len(data)), DEFAULT_FONT_SIZE, nil, 0)
		rl.GenTextureMipmaps(&f.texture)
		rl.SetTextureFilter(f.texture, .TRILINEAR)
		register(name, style, f)
	}
	load_font("sans", .Regular, inter_regular)
	load_font("sans", .Bold, inter_bold)
	load_font("sans", .Italic, inter_italic)
	load_font("mono", .Regular, fira_code_regular)
	load_font("mono", .Bold, fira_code_bold)
	load_font("serif", .Regular, noto_serif_regular)
	load_font("serif", .Bold, noto_serif_bold)
	load_font("serif", .Italic, noto_serif_italic)
}
```

- [ ] **Step 3: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success.

- [ ] **Step 4: Smoke test that italic font loads**

Boot any app and check stderr for raylib font load errors:

```bash
./build/redin --dev test/ui/smoke_app.fnl > /tmp/srv.log 2>&1 &
APPPID=$!
sleep 1
grep -iE "font|error" /tmp/srv.log | head
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Expected: no errors about Inter-Italic.ttf or NotoSerif-Italic.ttf.

- [ ] **Step 5: Commit**

```bash
git add src/redin/font/Inter-Italic.ttf src/redin/font/NotoSerif-Italic.ttf src/redin/font/embedded.odin
git commit -m "$(cat <<'EOF'
feat(font): embed Inter Italic and Noto Serif Italic

Adds italic glyphs for the sans and serif font families. Mono italic
falls back to mono regular per the existing font.get fallback chain.
~260KB binary growth, used by markdown rendering (issue #100).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `markdown` field on `NodeText` + bridge parsing

**Files:**
- Modify: `src/redin/types/view_tree.odin`
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add the field**

In `src/redin/types/view_tree.odin`, find the `NodeText` struct. Add a `markdown: bool` field:

```bash
grep -n "NodeText ::" src/redin/types/view_tree.odin
```

Open the file at that line, find the existing fields (likely `aspect`, `content`, `layout`, `not_selectable`, `overflow`, `id` if present, etc.), and add:

```odin
NodeText :: struct {
    // ...existing fields...
    markdown: bool,
}
```

- [ ] **Step 2: Parse the attr**

In `src/redin/bridge/bridge.odin`, find `lua_read_node` and the `case "text":` branch:

```bash
grep -n 'case "text"' src/redin/bridge/bridge.odin
```

After the existing attr reads (aspect, content, etc.), add:

```odin
lua_getfield(L, attrs_idx, "markdown")
defer lua_pop(L, 1)
if lua_isboolean(L, -1) {
    t.markdown = lua_toboolean(L, -1) != 0
}
```

(Use whatever struct identifier the existing code uses for the under-construction text node — e.g. `t`, `text_node`, etc. Verify by reading the surrounding code.)

The `defer lua_pop` should match the surrounding pattern; if other attr reads use a different convention (e.g. an immediate `lua_pop(L, 1)` with no defer), match that style.

If `lua_isboolean` is not available in the existing helpers, look for `lua_toboolean(L, -1)` directly (it returns 0/1 for non-booleans too). Use the same pattern as a sibling boolean attr (e.g. if `:not-selectable` is parsed with `lua_toboolean`, mirror that exactly).

- [ ] **Step 3: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success.

- [ ] **Step 4: Smoke test**

Write a temporary fixture with `:markdown true` and verify the field is parsed:

```bash
cat > /tmp/md_smoke.fnl <<'EOF'
(local dataflow (require :dataflow))
(dataflow.init {})
(fn _G.main_view []
  [:text {:markdown true} "hello"])
EOF

./build/redin --dev /tmp/md_smoke.fnl > /tmp/srv.log 2>&1 &
APPPID=$!
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" http://localhost:$PORT/frames | head -c 200
echo
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```

Expected: app boots without crashing and `/frames` returns the text node. The output won't yet show markdown rendering (Task 5 wires the renderer). The point of this smoke test is "no crash, no parser error". Look at /tmp/srv.log for parser warnings.

- [ ] **Step 5: Commit**

```bash
git add src/redin/types/view_tree.odin src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(types): NodeText.markdown attribute

Boolean field on NodeText, parsed from :markdown attr in lua_read_node.
Default false; the renderer's behavior is unchanged until later commits
add the markdown render path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Markdown parser (TDD)

**Files:**
- Create: `src/redin/markdown/parser.odin`
- Create: `src/redin/markdown/parser_test.odin`

- [ ] **Step 1: Write failing tests**

Create `src/redin/markdown/parser_test.odin`:

```odin
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
	// Two spaces before newline = soft break, kept as \n inside the span.
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```
Expected: FAIL — `parse` / `Span_Style` not defined.

- [ ] **Step 3: Implement `parser.odin`**

Create `src/redin/markdown/parser.odin`:

```odin
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
// the supplied allocator (default: context.allocator). The returned slices
// reference into the input string OR into allocator-owned strings (for soft
// breaks and unmatched delimiters that need joining); both shapes are valid.
parse :: proc(src: string, allocator := context.allocator) -> []Block {
	context.allocator = allocator

	blocks: [dynamic]Block
	// Split into paragraphs by blank lines.
	paragraphs := split_paragraphs(src)
	for p in paragraphs {
		spans := parse_inline(p)
		append(&blocks, Block{kind = .Paragraph, spans = spans})
	}
	return blocks[:]
}

split_paragraphs :: proc(src: string) -> []string {
	// A paragraph break is a blank line: \n\n or \n\r\n.
	out: [dynamic]string
	start := 0
	i := 0
	for i < len(src) {
		// Look for "\n\n" (or "\n\r\n").
		if src[i] == '\n' {
			j := i + 1
			// Skip optional CR.
			if j < len(src) && src[j] == '\r' do j += 1
			if j < len(src) && src[j] == '\n' {
				// Found paragraph break.
				if i > start {
					append(&out, src[start:i])
				}
				// Consume any further blank lines.
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

// Replace "  \n" (two-space soft break) with "\n" while keeping other newlines.
// The span text retains \n for soft breaks; layout treats \n as a forced break.
process_soft_breaks :: proc(s: string) -> string {
	// Fast path: nothing to do.
	if !strings.contains(s, "  \n") && !strings.contains(s, "\n") {
		return s
	}
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		// Detect "  \n" (or "  \r\n").
		if i + 2 < len(s) && s[i] == ' ' && s[i+1] == ' ' && s[i+2] == '\n' {
			strings.write_byte(&b, '\n')
			i += 3
			continue
		}
		// Drop other \n (collapse to space) so paragraphs flow naturally.
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

// Parse inline spans within one paragraph.
// Rules:
//   ** ... **   -> Bold (greedy)
//   * ... *     -> Italic
//   _ ... _     -> Italic
//   ` ... `     -> Code
//   "  \n"      -> soft break (kept as \n in span text)
// First opening delimiter wins; inner delimiters are literal.
// Unmatched delimiters: emitted as literal text.
parse_inline :: proc(src: string) -> []Span {
	pre := process_soft_breaks(src)
	out: [dynamic]Span
	current := strings.builder_make()
	i := 0

	flush_regular :: proc(out: ^[dynamic]Span, b: ^strings.Builder) {
		if strings.builder_len(b^) > 0 {
			append(out, Span{style = .Regular, text = strings.to_string(b^)})
			// Reset builder by clearing — strings.builder_reset.
			strings.builder_reset(b)
		}
	}

	for i < len(pre) {
		c := pre[i]
		// Try `**...**`
		if c == '*' && i + 1 < len(pre) && pre[i+1] == '*' {
			if close_idx := find_close_double(pre, i + 2, '*'); close_idx >= 0 {
				flush_regular(&out, &current)
				append(&out, Span{style = .Bold, text = pre[i+2:close_idx]})
				i = close_idx + 2
				continue
			}
		}
		// Single * or _ for italic.
		if c == '*' || c == '_' {
			if close_idx := find_close_single(pre, i + 1, c); close_idx >= 0 {
				flush_regular(&out, &current)
				append(&out, Span{style = .Italic, text = pre[i+1:close_idx]})
				i = close_idx + 1
				continue
			}
		}
		// Code with backtick.
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
			// For `*`, ensure this isn't part of a `**`.
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```
Expected: 10 tests pass. (9 explicitly listed in Step 1 + any extra logic helpers; output should show "All tests were successful".)

If any test fails, debug. The most likely culprits:
- `test_unmatched_delimiter`: the `**` opener has no closer. The current `parse_inline` falls through and emits each `*` as regular text. Verify the output joins them as one Regular span with `**bold without close` literal.
- `test_no_nesting_v1`: when we open `**`, we look for `**` close (find_close_double); the `_inner_` between them is NOT recursively parsed. Verify the Bold span's `text` is `outer _inner_`.

- [ ] **Step 5: Commit**

```bash
git add src/redin/markdown/parser.odin src/redin/markdown/parser_test.odin
git commit -m "$(cat <<'EOF'
feat(markdown): inline parser for v1 markdown

Tokenizes bold (**...**), italic (*...* / _..._), code (\`...\`), paragraph
breaks (blank line), and soft breaks (two-space EOL). No nesting; first
opening delimiter wins. 10 unit tests cover each rule and a mixed input.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Layout (span-aware word-wrap)

**Files:**
- Create: `src/redin/markdown/render.odin`

- [ ] **Step 1: Implement layout**

Create `src/redin/markdown/render.odin`:

```odin
package markdown

import "core:strings"
import "../font"
import text_pkg "../text"
import rl "vendor:raylib"

Span_Box :: struct {
	style:  Span_Style,
	text:   string,
	x:      f32,
	y:      f32,
	width:  f32,
	height: f32,
}

Laid_Block :: struct {
	spans:        []Span_Box,
	total_height: f32,
}

// Maps a span style + base font name to the actual rl.Font.
font_for :: proc(style: Span_Style, base_name: string) -> rl.Font {
	switch style {
	case .Regular: return font.get(base_name, .Regular)
	case .Bold:    return font.get(base_name, .Bold)
	case .Italic:  return font.get(base_name, .Italic)
	case .Code:    return font.get("mono", .Regular)
	}
	return font.get(base_name, .Regular)
}

// Word-wrap a list of blocks. Each unit (whitespace-separated token, plus
// literal \n as a forced break) becomes one Span_Box. Greedy line-fill.
layout :: proc(
	blocks: []Block,
	base_font_name: string,
	base_font_size: f32,
	line_height_ratio: f32,
	max_width: f32,
	allocator := context.allocator,
) -> []Laid_Block {
	context.allocator = allocator
	lh := text_pkg.line_height(base_font_size, line_height_ratio)
	out: [dynamic]Laid_Block

	for blk, blk_idx in blocks {
		boxes: [dynamic]Span_Box
		// Cursor inside this block.
		cursor_x: f32 = 0
		cursor_y: f32 = 0
		line_height_acc: f32 = lh
		first_unit_on_line := true

		emit :: proc(boxes: ^[dynamic]Span_Box, style: Span_Style, text: string,
		             font_obj: rl.Font, font_size: f32, lh: f32,
		             cursor_x: ^f32, cursor_y: ^f32, max_width: f32,
		             first_unit_on_line: ^bool, base_name: string) {
			if len(text) == 0 do return
			cstr := strings.clone_to_cstring(text, context.temp_allocator)
			size := rl.MeasureTextEx(font_obj, cstr, font_size, 0)
			w := size.x
			// If this unit doesn't fit and we're not at line start, wrap.
			if !first_unit_on_line^ && cursor_x^ + w > max_width {
				cursor_x^ = 0
				cursor_y^ += lh
				first_unit_on_line^ = true
			}
			append(boxes, Span_Box{
				style = style, text = text,
				x = cursor_x^, y = cursor_y^,
				width = w, height = lh,
			})
			cursor_x^ += w
			first_unit_on_line^ = false
		}

		for span in blk.spans {
			fnt := font_for(span.style, base_font_name)
			// Tokenise on whitespace. Keep \n as forced break.
			text := span.text
			start := 0
			i := 0
			for i < len(text) {
				ch := text[i]
				if ch == '\n' {
					// Flush pending.
					if i > start {
						emit(&boxes, span.style, text[start:i], fnt,
							base_font_size, lh, &cursor_x, &cursor_y, max_width,
							&first_unit_on_line, base_font_name)
					}
					// Forced break.
					cursor_x = 0
					cursor_y += lh
					first_unit_on_line = true
					i += 1
					start = i
					continue
				}
				if ch == ' ' || ch == '\t' {
					// Flush word, then emit single-space unit (preserves spacing).
					if i > start {
						emit(&boxes, span.style, text[start:i], fnt,
							base_font_size, lh, &cursor_x, &cursor_y, max_width,
							&first_unit_on_line, base_font_name)
					}
					// Emit the whitespace as its own unit. If it would land at
					// line start (after a wrap), consume it (don't render).
					ws := text[i:i+1]
					i += 1
					if first_unit_on_line {
						// Skip whitespace at line start.
						start = i
						continue
					}
					emit(&boxes, span.style, ws, fnt, base_font_size, lh,
						&cursor_x, &cursor_y, max_width, &first_unit_on_line,
						base_font_name)
					start = i
					continue
				}
				i += 1
			}
			if start < len(text) {
				emit(&boxes, span.style, text[start:], fnt, base_font_size, lh,
					&cursor_x, &cursor_y, max_width, &first_unit_on_line,
					base_font_name)
			}
		}

		block_height := cursor_y + lh
		append(&out, Laid_Block{
			spans = boxes[:],
			total_height = block_height,
		})
		_ = blk_idx
	}
	return out[:]
}

// Free all per-Block allocations from a Laid_Block slice.
free_laid :: proc(laid: []Laid_Block) {
	for blk in laid {
		delete(blk.spans)
	}
	delete(laid)
}
```

(`text_pkg.line_height` exists at `src/redin/text/layout.odin`. Verify the import path matches the existing convention — check how other render code imports it.)

- [ ] **Step 2: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success. The package compiles even though `draw` and the wiring don't exist yet.

If the build fails because the package has no `draw` proc, that's fine — Task 5 adds it. But the build should at least pick up the new files. If the build fails because of missing imports, fix those.

- [ ] **Step 3: Commit**

```bash
git add src/redin/markdown/render.odin
git commit -m "$(cat <<'EOF'
feat(markdown): span-aware word-wrap layout

layout() takes parsed blocks + base font/size + max width and produces
Span_Box positions. Tokenises on whitespace, treats \n as a forced break,
greedy line-fill. Code spans use mono regular; bold/italic/regular use
the named family.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Draw step + wire into render.odin

**Files:**
- Modify: `src/redin/markdown/render.odin` (add `draw`)
- Modify: `src/redin/render.odin` (dispatch in `draw_text`)

- [ ] **Step 1: Add `draw` to `markdown/render.odin`**

Append to `src/redin/markdown/render.odin`:

```odin
// Draw a laid-out markdown tree into `rect` using `color` for non-code spans.
// Code spans get a subtle bg fill and use the mono font's color (same as `color`).
draw :: proc(laid: []Laid_Block, rect: rl.Rectangle, color: rl.Color, base_font_size: f32, base_font_name: string, line_height_ratio: f32) {
	lh := text_pkg.line_height(base_font_size, line_height_ratio)
	code_bg := rl.Color{60, 60, 70, 255}

	block_y_offset: f32 = 0
	for blk, blk_idx in laid {
		for span in blk.spans {
			x := rect.x + span.x
			y := rect.y + block_y_offset + span.y
			fnt := font_for(span.style, base_font_name)

			if span.style == .Code {
				rl.DrawRectangleRec(rl.Rectangle{x, y, span.width, lh}, code_bg)
			}

			cstr := strings.clone_to_cstring(span.text, context.temp_allocator)
			rl.DrawTextEx(fnt, cstr, rl.Vector2{x, y}, base_font_size, 0, color)
		}
		// Add a paragraph gap between blocks (but not after the last).
		block_y_offset += blk.total_height
		if blk_idx + 1 < len(laid) {
			block_y_offset += lh  // one extra line as paragraph spacing
		}
	}
}
```

- [ ] **Step 2: Wire into `render.draw_text`**

In `src/redin/render.odin`, find `draw_text` (around line 1330). After resolving font_size/text_color/font_name/font_weight/lh_ratio from theme, but BEFORE the existing `compute_lines` call, branch on `n.markdown`:

```odin
draw_text :: proc(idx: int, rect: rl.Rectangle, n: types.NodeText, theme: map[string]types.Theme) {
	if len(n.content) == 0 do return

	font_size: f32 = 18
	text_color := rl.BLACK
	font_name := "sans"
	font_weight: u8 = 0
	lh_ratio: f32 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do font_size = f32(t.font_size)
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
			lh_ratio = t.line_height
		}
	}

	if n.markdown {
		blocks := markdown.parse(n.content, context.temp_allocator)
		laid := markdown.layout(blocks, font_name, font_size, lh_ratio, rect.width, context.temp_allocator)
		markdown.draw(laid, rect, text_color, font_size, font_name, lh_ratio)
		return
	}

	// ...existing path: font.get + compute_lines + line drawing...
}
```

(Add `import "markdown"` at the top of `render.odin` if not already present.)

The `context.temp_allocator` is reset each frame at the top of the runtime loop, so per-frame markdown allocations are freed automatically.

- [ ] **Step 3: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success.

- [ ] **Step 4: Smoke test**

```bash
cat > /tmp/md_render.fnl <<'EOF'
(local dataflow (require :dataflow))
(local theme    (require :theme))
(theme.set-theme {:body {:font-size 16 :color [240 240 240] :line-height 1.5}})
(dataflow.init {})
(fn _G.main_view []
  [:vbox {}
    [:text {:markdown true :aspect :body}
           "**Bold** and _italic_ and `code` inline.

Second paragraph after a blank line."]])
EOF

./build/redin --dev /tmp/md_render.fnl > /tmp/srv.log 2>&1 &
APPPID=$!
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"
curl -sH "$H" http://localhost:$PORT/screenshot > /tmp/md_screenshot.png
file /tmp/md_screenshot.png
echo "size: $(stat -c%s /tmp/md_screenshot.png) bytes"
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```

Expected: `/tmp/md_screenshot.png` is a valid PNG of nontrivial size (>5KB). The Read tool can be used to inspect it visually if you want.

- [ ] **Step 5: Commit**

```bash
git add src/redin/markdown/render.odin src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(markdown): draw step + wire into draw_text

When n.markdown is true, draw_text dispatches to the markdown render
path: parse → layout → draw. Plain text path unchanged. Per-frame
allocations use context.temp_allocator (auto-freed each tick).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Test app + UI test

**Files:**
- Create: `test/ui/markdown_app.fnl`
- Create: `test/ui/test_markdown.bb`

- [ ] **Step 1: Test app**

Create `test/ui/markdown_app.fnl`:

```fennel
(local dataflow (require :dataflow))
(local theme    (require :theme))

(theme.set-theme
  {:surface {:bg [30 33 42] :padding [16 16 16 16]}
   :body    {:font-size 16 :color [240 240 240] :line-height 1.5}})

(dataflow.init {})

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:text {:id :md :markdown true :aspect :body}
           "**Bold** and _italic_ and `code` inline.

Second paragraph after a blank line.
Soft break here  
on the next line."]])
```

- [ ] **Step 2: UI test**

Create `test/ui/test_markdown.bb`:

```clojure
(require '[redin-test :refer :all]
         '[clojure.java.io :as io])

(defn- ensure-artifacts-dir []
  (let [d (io/file "test/ui/artifacts")]
    (when-not (.exists d) (.mkdirs d))))

(deftest markdown-attr-present
  (let [n (find-element {:id :md})]
    (assert n "markdown text node must exist")
    (assert (= true (get (frame-attrs n) :markdown))
            ":markdown true must round-trip in /frames")))

(deftest markdown-renders-without-error
  (ensure-artifacts-dir)
  (wait-ms 100)
  (screenshot "test/ui/artifacts/markdown_render.png"))
```

Note: `frame-attrs` is a private helper in `redin_test.bb`. If that namespace doesn't expose it, replace with explicit `(get-in n [1 :markdown])` (the attrs map is at index 1 of the frame node vector).

- [ ] **Step 3: Run the suite**

```bash
./build/redin --dev test/ui/markdown_app.fnl > /tmp/srv.log 2>&1 &
APPPID=$!
sleep 2
bb test/ui/run.bb test/ui/test_markdown.bb 2>&1 | tail -10
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
ls -la test/ui/artifacts/markdown_render.png
file test/ui/artifacts/markdown_render.png
```
Expected: 2/2 tests pass and the screenshot is a valid PNG.

- [ ] **Step 4: Visual inspection**

Read `test/ui/artifacts/markdown_render.png` (or copy it locally) and confirm:
- "Bold" renders bold.
- "italic" renders italic (slanted).
- "code" renders in monospace with a subtle dark bg.
- Two paragraphs separated by a visible vertical gap.
- Soft break wraps to the next line within the same paragraph.

If italic doesn't render slanted, the Inter Italic font may not have loaded — check Task 1.

- [ ] **Step 5: Commit**

```bash
git add test/ui/markdown_app.fnl test/ui/test_markdown.bb
git commit -m "$(cat <<'EOF'
test(ui): markdown rendering test app + suite

markdown_app.fnl exercises bold/italic/code/paragraph/soft-break.
test_markdown.bb asserts the :markdown attr round-trips through /frames
and writes a screenshot artifact for visual inspection.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Documentation

**Files:**
- Modify: `docs/core-api.md`
- Modify: `docs/reference/elements.md`
- Modify: `.claude/skills/redin-dev/SKILL.md`

- [ ] **Step 1: Update `docs/core-api.md`**

Find the `:text` attribute table or section. Add a row / paragraph documenting `:markdown`:

```markdown
- `:markdown` — boolean. When `true`, the node's content is parsed as
  inline markdown and rendered with appropriate font styles. Supported
  in v1: `**bold**`, `_italic_` / `*italic*`, `` `inline code` ``,
  paragraph breaks (blank line), soft line breaks (two-space EOL).
  Headings, lists, links, images, tables, and code blocks are not
  supported in v1 — see issue #100 for the follow-up.
```

- [ ] **Step 2: Update `docs/reference/elements.md`**

Find the `text` element's attribute table. Add a row:

```markdown
| `:markdown` | boolean | `false` | When `true`, render content as inline markdown (v1: bold, italic, inline code, paragraphs, soft breaks). |
```

- [ ] **Step 3: Update `.claude/skills/redin-dev/SKILL.md`**

Find the section listing `text` attributes (or the "node types" overview). Add a one-line note:

```markdown
NodeText accepts `:markdown` (boolean, default `false`); when `true`,
inline markdown is rendered (v1: bold, italic, code, paragraph breaks,
soft line breaks).
```

- [ ] **Step 4: Verify**

```bash
rg -n 'markdown' docs/ .claude/skills/ | head
```
Expected: hits in the three modified files.

- [ ] **Step 5: Commit**

```bash
git add docs/core-api.md docs/reference/elements.md .claude/skills/redin-dev/SKILL.md
git commit -m "$(cat <<'EOF'
docs: :markdown attribute on :text

Document the new :markdown attribute and its v1 syntax (bold, italic,
inline code, paragraphs, soft breaks). Notes the deferred features
behind issue #100.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Final verification

- [ ] **Step 1: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success.

- [ ] **Step 2: Fennel runtime tests**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```
Expected: all pass.

- [ ] **Step 3: Odin parser tests**

```bash
odin test src/redin/parser
```
Expected: all pass.

- [ ] **Step 4: Odin markdown tests**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```
Expected: 10/10 pass.

- [ ] **Step 5: Odin input tests**

```bash
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```
Expected: all pass.

- [ ] **Step 6: Full UI suite**

```bash
bash test/ui/run-all.sh --headless
```
Expected: all suites pass including `test_markdown` (2/2).

- [ ] **Step 7: Memory check**

```bash
./build/redin --dev --track-mem test/ui/markdown_app.fnl > /tmp/track.log 2>&1 &
APPPID=$!
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"
sleep 0.3
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
grep -iE "leak|outstanding" /tmp/track.log | head
```
Expected: no leak/outstanding lines from markdown code.

- [ ] **Step 8: No commit (verification only)**

---

## Self-review

- Spec coverage:
  - Italic fonts embedded → Task 1
  - `:markdown` attribute on NodeText → Task 2
  - Parser (Span_Style, Span, Block, parse) → Task 3
  - Layout (Span_Box, Laid_Block, layout) → Task 4
  - Draw + wire into draw_text → Task 5
  - Test app + UI test → Task 6
  - Docs → Task 7
  - Verification → Task 8
- Placeholder scan: no "TBD"/"TODO"/"add appropriate" patterns. The font-download step uses curl with concrete URLs (with documented fallbacks if the URLs go stale).
- Type consistency: `Span_Style`, `Span`, `Block_Kind`, `Block`, `Span_Box`, `Laid_Block`, `parse`, `layout`, `draw`, `free_laid` — used consistently across tasks.
- Note: the layout proc allocates `boxes` per block via the supplied allocator. Callers using `context.temp_allocator` (the wiring in Task 5) get auto-cleanup; callers using `context.allocator` must call `free_laid`. Documented at `free_laid`'s definition.
