# Markdown lists — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement bullet (`-`/`*`/`+`) and ordered (`1.`/`1)`) markdown lists with up to 8 levels of nesting (2-space indent step), single-paragraph items, tight only.

**Architecture:** Extend `markdown.Block_Kind` with a `List_Item` variant; add `ordered: bool` and `marker: string` fields on `Block`. A new `detect_list_item` helper recognises the marker pattern. `parse` is reorganised: each chunk's first line still gates heading detection (chunk-greedy), but a chunk with no heading walks lines to emit list-item and paragraph blocks as needed. Renderer handles `List_Item` blocks via a new layout branch that draws the marker and indents content; no theme schema changes.

**Tech Stack:** Odin (host), Raylib (font/text), Babashka + `redin-test` (UI tests).

**Spec:** `docs/superpowers/specs/2026-05-02-markdown-lists-design.md`

---

## File map

| Path | Change |
|---|---|
| `src/redin/markdown/parser.odin` | Add `List_Item` to `Block_Kind`; add `ordered`/`marker` fields to `Block`; add `detect_list_item`; restructure `parse` to walk lines per chunk when there's no heading |
| `src/redin/markdown/parser_test.odin` | Append unit tests for bullet, ordered, paren-marker, no-renumber, nested, mixed-markers, blank-separated, inline-bold inside item, list-then-paragraph |
| `src/redin/markdown/render.odin` | Add `LIST_INDENT_PX`, `LIST_MARKER_GAP_PX` constants; new layout branch for List_Item blocks (marker box + indented content + word-wrap continuation indent) |
| `test/ui/markdown_app.fnl` | Add a `:md-lists` text node with bullet, ordered, and nested samples |
| `test/ui/test_markdown.bb` | Add `md-lists-renders` assertion |
| `docs/core-api.md` | Add list syntax bullet under the `:markdown` attribute description |

Each task ends in a commit. Build + parser tests must pass at every commit:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

The branch is `feat/markdown-lists`, currently stacked on `feat/markdown-extended` (PR #107). Working directory: `/home/soeren/repos/private/redin`.

---

### Task 1: `Block_Kind.List_Item` + struct fields

**Files:**
- Modify: `src/redin/markdown/parser.odin` — `Block_Kind`, `Block`

Adds the data shape only. Parser still emits Paragraphs/Headings; tests still pass. The new `ordered` and `marker` fields are zero/empty for non-list blocks.

- [ ] **Step 1: Update enum + struct.** In `src/redin/markdown/parser.odin`, replace the `Block_Kind` and `Block` declarations:

```odin
Block_Kind :: enum u8 { Paragraph, Heading, List_Item }

Block :: struct {
	kind:    Block_Kind,
	level:   u8,        // heading 1..6, or list nesting depth 0..N
	ordered: bool,      // List_Item only
	marker:  string,    // List_Item only — owned, the literal marker text
	                    //   ("•" for bullet; "1." / "5)" for ordered)
	spans:   []Span,
}
```

- [ ] **Step 2: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean. The `markdown.layout` and `markdown.draw` switch (or implicit handling) won't trip on the new variant because they iterate by reading `blk.spans` regardless of `kind`. Heading-only branches in `build_markdown_params` use `if blk.kind == .Heading` which is unaffected by adding a new variant.

- [ ] **Step 3: Run parser tests.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: 20/20 still pass — adding a new enum variant and two zero-default fields doesn't change any existing block's content.

- [ ] **Step 4: Commit.**

```bash
git add src/redin/markdown/parser.odin
git commit -m "$(cat <<'EOF'
feat(markdown): add List_Item Block_Kind + ordered/marker fields

Data-shape only. Block.ordered defaults to false and Block.marker to ""
for non-list blocks, so all existing tests are unaffected. Parser does
not emit List_Item yet — that lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `detect_list_item` helper

**Files:**
- Modify: `src/redin/markdown/parser.odin` — add helper near `detect_heading`
- Modify: `src/redin/markdown/parser_test.odin` — add helper tests

The helper does pure pattern matching. It does not mutate the parser yet — Task 3 wires it into `parse`. Pure-function tests can run independently.

- [ ] **Step 1: Write failing tests.** Append to `src/redin/markdown/parser_test.odin`:

```odin
@(test)
test_detect_list_bullet :: proc(t: ^testing.T) {
	level, ordered, marker, body, ok := detect_list_item("- hello")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, level, u8(0))
	testing.expect_value(t, ordered, false)
	testing.expect_value(t, marker, "•")
	testing.expect_value(t, body, "hello")
}

@(test)
test_detect_list_bullet_star :: proc(t: ^testing.T) {
	level, ordered, marker, body, ok := detect_list_item("* hi")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, marker, "•")
	testing.expect_value(t, body, "hi")
}

@(test)
test_detect_list_bullet_plus :: proc(t: ^testing.T) {
	_, _, marker, _, ok := detect_list_item("+ ok")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, marker, "•")
}

@(test)
test_detect_list_ordered_dot :: proc(t: ^testing.T) {
	level, ordered, marker, body, ok := detect_list_item("1. first")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, level, u8(0))
	testing.expect_value(t, ordered, true)
	testing.expect_value(t, marker, "1.")
	testing.expect_value(t, body, "first")
}

@(test)
test_detect_list_ordered_paren :: proc(t: ^testing.T) {
	_, ordered, marker, _, ok := detect_list_item("12) twelve")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, ordered, true)
	testing.expect_value(t, marker, "12)")
}

@(test)
test_detect_list_nested :: proc(t: ^testing.T) {
	level, _, _, body, ok := detect_list_item("    - deep")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, level, u8(2))   // 4 spaces / 2
	testing.expect_value(t, body, "deep")
}

@(test)
test_detect_list_no_marker :: proc(t: ^testing.T) {
	_, _, _, _, ok := detect_list_item("plain text")
	testing.expect_value(t, ok, false)
}

@(test)
test_detect_list_no_space_after_marker :: proc(t: ^testing.T) {
	_, _, _, _, ok := detect_list_item("-foo")
	testing.expect_value(t, ok, false)
}

@(test)
test_detect_list_dash_only :: proc(t: ^testing.T) {
	_, _, _, _, ok := detect_list_item("-")
	testing.expect_value(t, ok, false)
}

@(test)
test_detect_list_caps_at_8 :: proc(t: ^testing.T) {
	// 20 spaces → would be level 10, capped at 8.
	level, _, _, _, ok := detect_list_item("                    - deep")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, level, u8(8))
}

@(test)
test_detect_list_tab_indent_rejected :: proc(t: ^testing.T) {
	// Tab is not a space — leading tab means line is not a list item.
	_, _, _, _, ok := detect_list_item("\t- foo")
	testing.expect_value(t, ok, false)
}
```

- [ ] **Step 2: Run tests, confirm failure.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: compile error — `detect_list_item` doesn't exist yet.

- [ ] **Step 3: Add `detect_list_item` to `parser.odin`.** Place it immediately after the existing `detect_heading` proc:

```odin
// Returns (level, ordered, marker, body, true) if `line` opens with
// optional ASCII spaces (only — no tabs), then a list marker, then a
// single space, then content. Levels: floor(leading_spaces / 2),
// capped at 8. Bullet markers (-, *, +) all return marker="•". Ordered
// markers <n>. and <n>) return the literal source ("1." / "12)").
detect_list_item :: proc(line: string) -> (
	level: u8, ordered: bool, marker: string, body: string, ok: bool,
) {
	i := 0
	for i < len(line) && line[i] == ' ' do i += 1
	indent := i
	if i >= len(line) do return 0, false, "", "", false

	c := line[i]

	// Bullet: -, *, + followed by a single space.
	if c == '-' || c == '*' || c == '+' {
		if i + 1 >= len(line) || line[i + 1] != ' ' do return 0, false, "", "", false
		level_int := indent / 2
		if level_int > 8 do level_int = 8
		return u8(level_int), false, "•", line[i + 2:], true
	}

	// Ordered: one or more digits, then '.' or ')', then a single space.
	if c >= '0' && c <= '9' {
		j := i
		for j < len(line) && line[j] >= '0' && line[j] <= '9' do j += 1
		if j == i do return 0, false, "", "", false
		if j >= len(line) do return 0, false, "", "", false
		suffix := line[j]
		if suffix != '.' && suffix != ')' do return 0, false, "", "", false
		if j + 1 >= len(line) || line[j + 1] != ' ' do return 0, false, "", "", false
		level_int := indent / 2
		if level_int > 8 do level_int = 8
		return u8(level_int), true, line[i:j + 1], line[j + 2:], true
	}

	return 0, false, "", "", false
}
```

- [ ] **Step 4: Run tests, confirm pass.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: 31/31 pass (20 prior + 11 new).

- [ ] **Step 5: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean.

- [ ] **Step 6: Commit.**

```bash
git add src/redin/markdown/parser.odin src/redin/markdown/parser_test.odin
git commit -m "$(cat <<'EOF'
feat(markdown): detect_list_item helper

Pure pattern-matching helper recognising bullet (-, *, +) and ordered
(<n>. / <n>)) markers with optional 2-space-step indent. Returns the
nesting level (capped at 8), whether the marker is ordered, the
rendered marker text ("•" for bullets, literal source for ordered),
and the trimmed body. Tabs in indent are rejected — only ASCII
spaces count.

Wired into the parser in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Restructure `parse` to emit List_Item blocks

**Files:**
- Modify: `src/redin/markdown/parser.odin` — refactor `parse`
- Modify: `src/redin/markdown/parser_test.odin` — append parse-level tests

The chunk-walk now emits List_Item blocks for marker lines and Paragraph blocks for buffered prose lines. Heading detection stays chunk-greedy (entire chunk → one Heading) when the chunk's first line is a heading — no behaviour change for existing content.

- [ ] **Step 1: Write failing parse-level tests.** Append to `src/redin/markdown/parser_test.odin`:

```odin
@(test)
test_bullet_list :: proc(t: ^testing.T) {
	blocks := parse("- a\n- b\n- c", context.temp_allocator)
	testing.expect_value(t, len(blocks), 3)
	for blk, idx in blocks {
		testing.expect_value(t, blk.kind, Block_Kind.List_Item)
		testing.expect_value(t, blk.level, u8(0))
		testing.expect_value(t, blk.ordered, false)
		testing.expect_value(t, blk.marker, "•")
		testing.expect_value(t, len(blk.spans), 1)
		expected := []string{"a", "b", "c"}[idx]
		testing.expect_value(t, blk.spans[0].text, expected)
	}
}

@(test)
test_ordered_list :: proc(t: ^testing.T) {
	blocks := parse("1. a\n2. b\n3. c", context.temp_allocator)
	testing.expect_value(t, len(blocks), 3)
	for blk, idx in blocks {
		testing.expect_value(t, blk.kind, Block_Kind.List_Item)
		testing.expect_value(t, blk.ordered, true)
		expected := []string{"1.", "2.", "3."}[idx]
		testing.expect_value(t, blk.marker, expected)
	}
}

@(test)
test_ordered_paren_marker :: proc(t: ^testing.T) {
	blocks := parse("1) a\n2) b", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].marker, "1)")
	testing.expect_value(t, blocks[1].marker, "2)")
}

@(test)
test_ordered_no_renumber :: proc(t: ^testing.T) {
	blocks := parse("5. a\n6. b", context.temp_allocator)
	testing.expect_value(t, blocks[0].marker, "5.")
	testing.expect_value(t, blocks[1].marker, "6.")
}

@(test)
test_list_nested :: proc(t: ^testing.T) {
	blocks := parse("- parent\n  - child\n  - sibling\n- back", context.temp_allocator)
	testing.expect_value(t, len(blocks), 4)
	testing.expect_value(t, blocks[0].level, u8(0))
	testing.expect_value(t, blocks[1].level, u8(1))
	testing.expect_value(t, blocks[2].level, u8(1))
	testing.expect_value(t, blocks[3].level, u8(0))
}

@(test)
test_list_mixed_markers :: proc(t: ^testing.T) {
	blocks := parse("- a\n* b\n+ c", context.temp_allocator)
	testing.expect_value(t, len(blocks), 3)
	for blk in blocks {
		testing.expect_value(t, blk.kind, Block_Kind.List_Item)
		testing.expect_value(t, blk.ordered, false)
		testing.expect_value(t, blk.marker, "•")
		testing.expect_value(t, blk.level, u8(0))
	}
}

@(test)
test_list_blank_separates :: proc(t: ^testing.T) {
	blocks := parse("- a\n\n- b", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Item)
	testing.expect_value(t, blocks[1].kind, Block_Kind.List_Item)
	testing.expect_value(t, blocks[0].spans[0].text, "a")
	testing.expect_value(t, blocks[1].spans[0].text, "b")
}

@(test)
test_list_with_inline_bold :: proc(t: ^testing.T) {
	blocks := parse("- **bold** item", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Item)
	testing.expect_value(t, len(blocks[0].spans), 2)
	testing.expect_value(t, blocks[0].spans[0].style, Span_Style.Bold)
	testing.expect_value(t, blocks[0].spans[0].text, "bold")
	testing.expect_value(t, blocks[0].spans[1].style, Span_Style.Regular)
	testing.expect_value(t, blocks[0].spans[1].text, " item")
}

@(test)
test_list_then_paragraph_no_blank :: proc(t: ^testing.T) {
	blocks := parse("- a\nplain text", context.temp_allocator)
	testing.expect_value(t, len(blocks), 2)
	testing.expect_value(t, blocks[0].kind, Block_Kind.List_Item)
	testing.expect_value(t, blocks[0].spans[0].text, "a")
	testing.expect_value(t, blocks[1].kind, Block_Kind.Paragraph)
	testing.expect_value(t, blocks[1].spans[0].text, "plain text")
}

@(test)
test_paragraph_then_list_no_blank :: proc(t: ^testing.T) {
	blocks := parse("intro\n- a\n- b", context.temp_allocator)
	testing.expect_value(t, len(blocks), 3)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Paragraph)
	testing.expect_value(t, blocks[0].spans[0].text, "intro")
	testing.expect_value(t, blocks[1].kind, Block_Kind.List_Item)
	testing.expect_value(t, blocks[2].kind, Block_Kind.List_Item)
}

@(test)
test_heading_chunk_still_greedy :: proc(t: ^testing.T) {
	// Heading absorbs the whole chunk (existing behaviour, preserved).
	blocks := parse("# title\nsubtitle text", context.temp_allocator)
	testing.expect_value(t, len(blocks), 1)
	testing.expect_value(t, blocks[0].kind, Block_Kind.Heading)
}
```

- [ ] **Step 2: Run tests, confirm failure.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: most new tests fail — current `parse` emits one Paragraph per chunk and never emits List_Item.

- [ ] **Step 3: Replace `parse`.** In `src/redin/markdown/parser.odin`, replace the existing `parse` proc (the body that loops over `paragraphs` from `split_paragraphs`) with:

```odin
parse :: proc(src: string, allocator := context.allocator) -> []Block {
	context.allocator = allocator

	blocks: [dynamic]Block
	paragraphs := split_paragraphs(src)
	for chunk in paragraphs {
		// Heading detection stays chunk-greedy: if the chunk opens with
		// `#`-space, the entire chunk becomes one Heading block. This
		// preserves the existing parser's contract for headings.
		if level, body, is_h := detect_heading(chunk); is_h {
			spans := parse_inline(body)
			append(&blocks, Block{kind = .Heading, level = level, spans = spans})
			continue
		}

		// Otherwise walk the chunk line-by-line, emitting List_Item
		// blocks for marker lines and a Paragraph block for any
		// buffered prose.
		para_buf: strings.Builder
		strings.builder_init(&para_buf)
		defer strings.builder_destroy(&para_buf)

		flush_paragraph :: proc(blocks: ^[dynamic]Block, b: ^strings.Builder) {
			if strings.builder_len(b^) == 0 do return
			text := strings.clone(strings.to_string(b^))
			spans := parse_inline(text)
			append(blocks, Block{kind = .Paragraph, spans = spans})
			strings.builder_reset(b)
		}

		i := 0
		for i < len(chunk) {
			// Find end of this line.
			j := i
			for j < len(chunk) && chunk[j] != '\n' do j += 1
			line := chunk[i:j]

			if level, ordered, marker, body, is_li := detect_list_item(line); is_li {
				flush_paragraph(&blocks, &para_buf)
				marker_owned := strings.clone(marker)
				spans := parse_inline(body)
				append(&blocks, Block{
					kind    = .List_Item,
					level   = level,
					ordered = ordered,
					marker  = marker_owned,
					spans   = spans,
				})
			} else {
				if strings.builder_len(para_buf) > 0 {
					strings.write_byte(&para_buf, '\n')
				}
				strings.write_string(&para_buf, line)
			}

			i = j + 1   // skip past the '\n' (or past end-of-chunk).
		}
		flush_paragraph(&blocks, &para_buf)
	}
	return blocks[:]
}
```

Note on the marker string: `detect_list_item` returns either the literal `"•"` (which is a string-constant slice of the source code's UTF-8 bytes) or a slice into the input `line` (for ordered markers). Both are non-owning. `strings.clone(marker)` copies it into the parser's allocator so the resulting `Block.marker` outlives the input slice.

- [ ] **Step 4: Run tests, confirm pass.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: 42/42 pass (20 prior + 11 detect_list_item + 11 parse-level).

- [ ] **Step 5: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean. The renderer treats List_Item blocks like any other block (it iterates `blk.spans`); they render at the host font_size with no marker and no indent. Visual wiring lands in Task 4.

- [ ] **Step 6: Smoke check.**

```bash
./build/redin --dev test/ui/markdown_app.fnl > /tmp/md.log 2>&1 &
SPID=$!
for i in $(seq 1 30); do [ -f .redin-port ] && break; sleep 0.2; done
curl -s -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/frames | head -c 100
echo
curl -s -H "Authorization: Bearer $(cat .redin-token)" -X POST http://localhost:$(cat .redin-port)/shutdown >/dev/null
wait $SPID 2>/dev/null
echo "exit=$?"
rm -f .redin-port .redin-token
```

Expected: clean exit. Existing markdown_app.fnl content has no list markers, so behaviour is unchanged.

- [ ] **Step 7: Commit.**

```bash
git add src/redin/markdown/parser.odin src/redin/markdown/parser_test.odin
git commit -m "$(cat <<'EOF'
feat(markdown): emit List_Item blocks from parse

Each chunk's first line still gates heading detection (chunk-greedy
behaviour preserved). Otherwise, the chunk walks line-by-line: list-
item lines become List_Item blocks; runs of non-marker prose are
buffered into Paragraph blocks. Mixed paragraph + list content within
one chunk works without requiring blank lines.

List_Item blocks carry the parsed inline content. The marker text is
heap-cloned so it outlives the input slice. Renderer wiring lands in
the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Render List_Item blocks (marker + indent + content)

**Files:**
- Modify: `src/redin/markdown/render.odin` — add constants + List_Item branch in `layout`

The renderer reuses the existing per-block layout loop. For List_Item blocks, we prepend a marker `Span_Box` at the appropriate indent and shift the starting cursor for the item's spans so they wrap under the marker's right edge. Continuation lines (word-wrap) reset to the same indent so wrapped text aligns under the first character of the item content.

- [ ] **Step 1: Add layout constants.** In `src/redin/markdown/render.odin`, add near the top after imports (before `Block_Params`):

```odin
LIST_INDENT_PX     :: 24.0
LIST_MARKER_GAP_PX :: 8.0
```

- [ ] **Step 2: Update `layout` to handle List_Item blocks.** Inside the existing `for blk, blk_idx in blocks` loop, add per-block setup that runs before the span-iteration loop:

The current loop body starts with:

```odin
for blk, blk_idx in blocks {
	bp := params[blk_idx]
	lh := text_pkg.line_height(bp.font_size, bp.line_height)
	boxes: [dynamic]Span_Box
	cursor_x: f32 = 0
	cursor_y: f32 = 0
	first_unit_on_line := true
```

Add a content_indent computation + marker emission right after `first_unit_on_line := true`:

```odin
	// List items: indent + emit a marker box. Track content_indent so
	// word-wrap continuation lines align under the first content
	// character (not flush-left).
	content_indent: f32 = 0
	if blk.kind == .List_Item {
		content_indent = f32(blk.level) * LIST_INDENT_PX
		if len(blk.marker) > 0 {
			marker_fnt := font_for(.Regular, base_font_name)
			cstr := strings.clone_to_cstring(blk.marker, context.temp_allocator)
			size := rl.MeasureTextEx(marker_fnt, cstr, bp.font_size, 0)
			append(&boxes, Span_Box{
				style  = .Regular,
				text   = blk.marker,
				x      = content_indent,
				y      = cursor_y,
				width  = size.x,
				height = lh,
			})
			content_indent += size.x + LIST_MARKER_GAP_PX
		}
		cursor_x = content_indent
		first_unit_on_line = false  // marker counts as the first unit on this line
	}
```

Then update the existing `emit` proc and the inner loops so word-wrap returns to `content_indent` (not 0) when it wraps. The cleanest way: change the two `cursor_x^ = 0` (in `emit`'s overflow branch) and `cursor_x = 0` (in the `'\n'` forced-break branch) to use a closed-over `content_indent`. The existing `emit` is a nested proc; pass `content_indent` as an extra parameter:

Edit `emit`'s signature to add `content_indent: f32`:

```odin
emit :: proc(boxes: ^[dynamic]Span_Box, style: Span_Style, text: string,
             font_obj: rl.Font, font_size: f32, lh: f32,
             cursor_x: ^f32, cursor_y: ^f32, max_width: f32,
             first_unit_on_line: ^bool, content_indent: f32) {
	if len(text) == 0 do return
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	size := rl.MeasureTextEx(font_obj, cstr, font_size, 0)
	w := size.x
	if !first_unit_on_line^ && cursor_x^ + w > max_width {
		cursor_x^ = content_indent
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
```

Update every `emit(...)` call site in the proc to pass `content_indent` as the last argument. There are four `emit` calls in the existing loop (two for word-bounded segments, one for whitespace, one for the final tail).

Update the forced-break branch:

```odin
if ch == '\n' {
	if i > start {
		emit(&boxes, span.style, text[start:i], fnt,
			bp.font_size, lh, &cursor_x, &cursor_y, max_width,
			&first_unit_on_line, content_indent)
	}
	cursor_x = content_indent
	cursor_y += lh
	first_unit_on_line = true
	i += 1
	start = i
	continue
}
```

(Existing tests use `\n` only inside paragraph spans — soft breaks. With `content_indent = 0` for paragraphs, behaviour is unchanged. For list items, `\n` shouldn't occur in spans because list items are single-line, but we set the right value defensively.)

- [ ] **Step 3: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean.

- [ ] **Step 4: Run parser tests (sanity).**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: 42/42 still pass — Task 4 doesn't touch the parser.

- [ ] **Step 5: Smoke test the existing markdown_app.fnl.**

```bash
./build/redin --dev test/ui/markdown_app.fnl > /tmp/md.log 2>&1 &
SPID=$!
for i in $(seq 1 30); do [ -f .redin-port ] && break; sleep 0.2; done
bb test/ui/run.bb test/ui/test_markdown.bb 2>&1 | tail -10
curl -s -H "Authorization: Bearer $(cat .redin-token)" -X POST http://localhost:$(cat .redin-port)/shutdown >/dev/null
wait $SPID 2>/dev/null
echo "exit=$?"
rm -f .redin-port .redin-token
```

Expected: existing markdown UI tests (3 tests) still pass; clean exit. The test fixture has no list content, so behaviour is unchanged.

- [ ] **Step 6: Commit.**

```bash
git add src/redin/markdown/render.odin
git commit -m "$(cat <<'EOF'
feat(markdown): render List_Item blocks (marker + indent)

For List_Item blocks the layout pass emits a marker Span_Box at
(level * 24px), advances the cursor by marker_width + 8px, then lays
out the item's content from that x. Word-wrap continuation lines
return to the content_indent so wrapped text aligns under the first
character of the item — not flush-left.

Marker uses Regular font face and Style_Theme.base_color (no separate
:list-marker aspect in v1). 24px-per-level indent and 8px marker gap
are hardcoded constants.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: UI test fixture + assertion

**Files:**
- Modify: `test/ui/markdown_app.fnl` — add `:md-lists` text node
- Modify: `test/ui/test_markdown.bb` — add `md-lists-renders` test

The existing fixture defines `:md` and `:md-extended` nodes (preserved verbatim). Add a third sibling.

- [ ] **Step 1: Add `:md-lists` to the fixture.** In `test/ui/markdown_app.fnl`, append a new `:text` node inside the `:vbox` after `:md-extended`:

```fennel
    [:text {:id :md-lists :markdown true :aspect :body}
           "Shopping list:

- apples
- bananas
  - peeled
  - whole
- cherries

Steps:

1. preheat oven
2. mix batter
3. bake"]
```

The full file (showing the existing nodes plus the new one) is the union of:
- Existing `:md` text node (preserved verbatim).
- Existing `:md-extended` text node (preserved verbatim).
- New `:md-lists` text node (above).

All three siblings live in the `:vbox`'s children.

- [ ] **Step 2: Add `md-lists-renders` test.** Append to `test/ui/test_markdown.bb`:

```clojure
(deftest md-lists-renders
  (let [el (find-element {:id :md-lists})]
    (assert el "md-lists must exist in /frames")
    (let [r (rect-of el)]
      (assert r "md-lists must have a :rect")
      ;; "Shopping list:" + 3 bullets + 2 nested + "Steps:" + 3 ordered = 10 lines.
      ;; At body font-size 24 × line-height 1.5 ≈ 36px each → ~360px.
      ;; Threshold 280 is conservative; absorbs blank-line / paragraph-spacing
      ;; variance.
      (assert (>= (:h r) 280)
              (str "md-lists rect height should be >= 280, got " (:h r))))))
```

- [ ] **Step 3: Run the markdown UI test.**

```bash
./build/redin --dev test/ui/markdown_app.fnl > /tmp/md.log 2>&1 &
SPID=$!
for i in $(seq 1 30); do [ -f .redin-port ] && break; sleep 0.2; done
bb test/ui/run.bb test/ui/test_markdown.bb 2>&1 | tail -10
curl -s -H "Authorization: Bearer $(cat .redin-token)" -X POST http://localhost:$(cat .redin-port)/shutdown >/dev/null
wait $SPID 2>/dev/null
echo "exit=$?"
rm -f .redin-port .redin-token
```

Expected: 4 tests pass (`markdown-attr-present`, `markdown-renders-without-error`, `md-extended-renders`, `md-lists-renders`); clean server exit.

If `md-lists-renders` fails because the rect height is below 280, look at the actual value reported in the assertion error and either:
- Lower the threshold if the value is close (e.g. 240–280) — font metric variance.
- Investigate further if the value is far below — likely the renderer didn't lay out the list items as expected (e.g. all on one line, or marker overlap).

- [ ] **Step 4: Commit.**

```bash
git add test/ui/markdown_app.fnl test/ui/test_markdown.bb
git commit -m "$(cat <<'EOF'
test(ui): markdown — bullet, ordered, and nested lists sample

Adds :md-lists exercising bullet items, an ordered list, and a 1-level
nested bullet sublist. Asserts rect height ≥ 280px (10 visible lines at
body font-size 24).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Docs

**Files:**
- Modify: `docs/core-api.md` — extend the `:markdown` attribute description

- [ ] **Step 1: Find the `:markdown` table row.**

```bash
grep -n "markdown" docs/core-api.md | head
```

Locate the row introduced earlier in #107. The current text mentions headings and nested emphasis but not lists.

- [ ] **Step 2: Add list syntax to the attribute description.** Edit the `markdown` row in `docs/core-api.md` so it now reads (replace the existing row):

```
| `markdown` | boolean                 | text (default `false`; when `true`, content is parsed as inline markdown — supports `**bold**`, `_italic_` / `*italic*`, `` `inline code` ``, nested emphasis like `**bold _italic_**`, headings (`#`–`######`), bullet lists (`- `, `* `, `+ ` — `•` glyph), ordered lists (`<n>.` and `<n>) `), nesting at 2-space indent steps (up to 8 levels), paragraph breaks via blank line, and soft line breaks via two-space EOL. List markers must be followed by a space; nesting indent must be ASCII spaces (tabs not normalised). Per-aspect `:bold` / `:italic` / `:code` sub-tables and `:h1`–`:h6` aspects control rendering — see [theme reference](reference/theme.md). Links, images, tables, triple-backtick code blocks, and multi-paragraph list items are not yet supported) |
```

Use `Edit` for the swap.

If `docs/core-api.md` has the same wording duplicated in a prose paragraph (e.g. lines ~672 from #107), update that occurrence as well to mention lists.

- [ ] **Step 3: Verify the change.**

```bash
grep -n "bullet lists" docs/core-api.md     # should hit the new line(s)
grep -n "Lists, links, images" docs/core-api.md  # should return nothing — old text is gone
```

- [ ] **Step 4: Commit.**

```bash
git add docs/core-api.md
git commit -m "$(cat <<'EOF'
docs: markdown — bullet + ordered lists with 2-space nesting

Documents the new :markdown list syntax (#102) added in this PR.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

After all 6 tasks:

- [ ] **Build (default):**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

- [ ] **Markdown parser tests:**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: 42/42 (20 pre-existing + 11 detect_list_item + 11 parse-level).

- [ ] **Runtime tests:**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: 129/129.

- [ ] **Full UI suite (headless):**

```bash
bash test/ui/run-all.sh --headless
```

Expected: all suites pass, including the 4-test markdown suite.

- [ ] **REDIN_AGENT build + suite:**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin
bash test/ui/run-all.sh --headless
```

Expected: all suites pass.

Then push the branch and open a PR titled `feat(markdown): bullet + ordered lists with 2-space nesting`. Body references issue #102 (lists checkbox) and notes the dependency on PR #107.
