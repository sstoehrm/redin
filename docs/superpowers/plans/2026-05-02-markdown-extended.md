# Markdown extended (tier 1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement headings (`#`–`######`), nested inline styles (`**bold _italic_**`), and per-style theme overrides (`{:bold {…} :italic {…} :code {…}}`) for `:markdown` text nodes. Closes #105.

**Architecture:** Extend `markdown.Block_Kind` and `markdown.Span_Style`, make `parse_inline` recursive. Add a `Style_Override` sub-struct to `types.Theme` and parse three new sub-tables in `lua_to_theme`. Heading sizing reads `:h1`–`:h6` aspects with non-zero-field inheritance from the host aspect, falling back to a hardcoded scale table. `font.get` gains one fallback arm so `Bold_Italic` resolves to `Bold` when no Bold-Italic face is loaded.

**Tech Stack:** Odin (host), Raylib (font/render), Fennel/Lua (theme schema), Babashka + `redin-test` (UI tests).

**Spec:** `docs/superpowers/specs/2026-05-02-markdown-extended-design.md`

---

## File map

| Path | Change |
|---|---|
| `src/redin/font/font.odin` | Add `Bold_Italic → Bold` fallback in `get` |
| `src/redin/markdown/parser.odin` | New `Block_Kind.Heading` + `level`; `Span_Style.Bold_Italic`; recursive `parse_inline` |
| `src/redin/markdown/parser_test.odin` | Heading + nested-style unit tests |
| `src/redin/markdown/render.odin` | `font_for(.Bold_Italic)`; per-block heading size in `layout`; per-style overrides in `draw` |
| `src/redin/types/theme.odin` | `Style_Override` struct + `bold`/`italic`/`code` fields on `Theme` |
| `src/redin/bridge/bridge.odin` | `lua_get_style_override` + parse three sub-tables in `lua_to_theme` |
| `src/redin/render.odin` | Build `Style_Theme` and forward heading scale + theme map into `markdown.layout` / `markdown.draw` |
| `test/ui/markdown_app.fnl` | Add heading + nested-style + theme-override sample |
| `test/ui/test_markdown.bb` | Assert new sample renders (rect height ≥ baseline + crash-free) |
| `docs/core-api.md` | One bullet under `:markdown` for the new syntax |
| `docs/reference/theme.md` | Document `bold`/`italic`/`code` sub-tables and `:h1`–`:h6` aspects |

Each task ends in a commit. Build (`odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`) and unit tests (`luajit test/lua/runner.lua test/lua/test_*.fnl` for runtime; `odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -out:build/markdown_tests` for parser) must pass at every commit.

---

### Task 1: Bold_Italic font fallback in `font.get`

**Files:**
- Modify: `src/redin/font/font.odin:8-15` (`Font_Style` enum)
- Modify: `src/redin/font/font.odin:41-58` (`get` proc)

`Bold_Italic` becomes a first-class `Font_Style`. When the requested face is not registered, `get` first tries `Bold` (closest visual approximation) before falling back to `Regular`. Existing two-arg fallback (style → Regular) for plain Italic / Bold remains.

- [ ] **Step 1: Add `Bold_Italic` to the enum.** Edit `src/redin/font/font.odin`:

```odin
Font_Style :: enum {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
}
```

- [ ] **Step 2: Extend the `get` fallback chain.** Replace the `get` proc in `src/redin/font/font.odin` with:

```odin
get :: proc(name: string, style: Font_Style) -> rl.Font {
	if f, ok := fonts[Font_Key{name, style}]; ok {
		return f
	}
	// Bold_Italic falls back to Bold first (closer visual match than Regular).
	if style == .Bold_Italic {
		if f, ok := fonts[Font_Key{name, .Bold}]; ok {
			return f
		}
	}
	if style != .Regular {
		if f, ok := fonts[Font_Key{name, .Regular}]; ok {
			return f
		}
	}
	if name != default_font_name {
		if f, ok := fonts[Font_Key{default_font_name, style}]; ok {
			return f
		}
	}
	if name != default_font_name || style != .Regular {
		if f, ok := fonts[Font_Key{default_font_name, .Regular}]; ok {
			return f
		}
	}
	return rl.GetFontDefault()
}
```

- [ ] **Step 3: Add `style_from_weight` arm if needed.** The current `style_from_weight` maps `.NORMAL → .Regular`, `.BOLD → .Bold`, `.ITALIC → .Italic`. No `Bold_Italic` weight exists, so leave it untouched. Confirm by reading lines 60–73 of `font.odin`.

- [ ] **Step 4: Build.** Run:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build (no enum-exhaustiveness errors — only `font_for` in markdown/render.odin uses Font_Style and it has a default fallback).

- [ ] **Step 5: Commit.**

```bash
git add src/redin/font/font.odin
git commit -m "$(cat <<'EOF'
feat(font): add Bold_Italic style with Bold fallback

Lets the markdown renderer request a Bold_Italic face without forcing
new asset embedding — when the face isn't registered, get() now tries
Bold before falling back to Regular.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Heading block parsing

**Files:**
- Modify: `src/redin/markdown/parser.odin:11-17` (`Block_Kind`, `Block`)
- Modify: `src/redin/markdown/parser.odin:22-32` (`parse`)
- Modify: `src/redin/markdown/parser_test.odin` (append tests)

A paragraph that starts with 1–6 `#` followed by space becomes a `Heading` block. Trailing `#` runs and surrounding whitespace are stripped. Paragraphs starting with 7+ `#` (no space within first 6) stay as paragraphs.

- [ ] **Step 1: Write failing tests.** Append to `src/redin/markdown/parser_test.odin`:

```odin
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
```

- [ ] **Step 2: Run tests, confirm failure.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_NAMES=test_heading_h1
```

Expected: compile error referencing `Block_Kind.Heading` and `blocks[0].level` — fields don't exist yet. (We use a name filter so existing tests aren't built; if the filter syntax differs in this Odin version, drop it and let unrelated existing tests run.)

- [ ] **Step 3: Extend `Block_Kind` and `Block`.** Replace lines 11–17 of `src/redin/markdown/parser.odin`:

```odin
Block_Kind :: enum u8 { Paragraph, Heading }

Block :: struct {
	kind:  Block_Kind,
	level: u8,        // 1..6 for Heading; 0 for Paragraph
	spans: []Span,
}
```

- [ ] **Step 4: Add heading detector + update `parse`.** Replace lines 22–32 of `src/redin/markdown/parser.odin`:

```odin
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
```

- [ ] **Step 5: Run tests, confirm pass.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: all parser tests pass (existing + 6 new heading tests). If the test runner reports unrelated failures, fix only the heading-related ones in this task.

- [ ] **Step 6: Build the host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build. The renderer's `for blk in laid` loop iterates blocks regardless of `kind`, so headings render at paragraph size for now (Task 4 fixes that).

- [ ] **Step 7: Commit.**

```bash
git add src/redin/markdown/parser.odin src/redin/markdown/parser_test.odin
git commit -m "$(cat <<'EOF'
feat(markdown): heading block parsing (#…######)

Paragraphs that start with 1..6 # plus a space become Heading blocks
with the level captured. Trailing # runs and surrounding whitespace
are stripped per CommonMark. 7+ # or no space → still a paragraph.

Renders at paragraph size for now; Task 4 wires per-level sizing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Recursive `parse_inline` + `Bold_Italic` span style

**Files:**
- Modify: `src/redin/markdown/parser.odin:5` (`Span_Style`)
- Modify: `src/redin/markdown/parser.odin:88-139` (`parse_inline`)
- Modify: `src/redin/markdown/parser_test.odin` (append tests)

`parse_inline` becomes recursive: when it matches an emphasis delimiter, the body is re-tokenised. The merge rule:

| Outer  | Inner   | Result        |
|--------|---------|---------------|
| Bold   | Italic  | `Bold_Italic` |
| Italic | Bold    | `Bold_Italic` |
| Bold   | Bold    | `Bold` (collapse) |
| Italic | Italic  | `Italic` (collapse) |
| Bold/Italic/Bold_Italic | Code | `Code` (code wins) |
| Bold_Italic | Bold/Italic | `Bold_Italic` (collapse) |
| any    | Regular | outer style   |

Code stays a leaf — no recursion inside backticks.

- [ ] **Step 1: Write failing tests.** Append to `src/redin/markdown/parser_test.odin`:

```odin
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
```

- [ ] **Step 2: Run tests, confirm failure.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: the three new tests fail (current `parse_inline` produces 1 span containing the literal inner text or 2 spans without nested style merging). `Span_Style.Bold_Italic` does not exist yet — compile error.

- [ ] **Step 3: Add `Bold_Italic` to `Span_Style`.** Replace line 5 of `src/redin/markdown/parser.odin`:

```odin
Span_Style :: enum u8 { Regular, Bold, Italic, Bold_Italic, Code }
```

- [ ] **Step 4: Replace `parse_inline` with the recursive variant.** In `src/redin/markdown/parser.odin`, replace the `parse_inline` proc (lines ~86–139) and its helpers with:

```odin
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
	return inner  // unreachable, but keeps the compiler happy
}
```

- [ ] **Step 5: Run tests, confirm pass.**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: all parser tests pass (existing + 3 new nested-style tests + previously-added 6 heading tests).

- [ ] **Step 6: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: build fails — `font_for` in `src/redin/markdown/render.odin` switches on `Span_Style` and now misses the `.Bold_Italic` case. We fix it in the next step within this same commit (the renderer change is too small to split out cleanly).

- [ ] **Step 7: Add `Bold_Italic` arm to `font_for`.** In `src/redin/markdown/render.odin`, replace the `font_for` proc (lines 22–30):

```odin
font_for :: proc(style: Span_Style, base_name: string) -> rl.Font {
	switch style {
	case .Regular:     return font.get(base_name, .Regular)
	case .Bold:        return font.get(base_name, .Bold)
	case .Italic:      return font.get(base_name, .Italic)
	case .Bold_Italic: return font.get(base_name, .Bold_Italic)
	case .Code:        return font.get("mono", .Regular)
	}
	return font.get(base_name, .Regular)
}
```

- [ ] **Step 8: Build host binary again.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build.

- [ ] **Step 9: Commit.**

```bash
git add src/redin/markdown/parser.odin src/redin/markdown/parser_test.odin src/redin/markdown/render.odin
git commit -m "$(cat <<'EOF'
feat(markdown): nested inline styles + Bold_Italic span

parse_inline now recurses into emphasis bodies. **bold _italic_** emits
three spans (Bold, Bold_Italic, Bold). Code stays a leaf. Bold_Italic
inherits Bold's font face via font.get's fallback chain (Task 1).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Heading layout sizing

**Files:**
- Modify: `src/redin/markdown/render.odin:35-42` (`layout` signature)
- Modify: `src/redin/markdown/render.odin:42-130` (`layout` body — per-block size)
- Modify: `src/redin/markdown/render.odin:143-166` (`draw` — per-block size)
- Modify: `src/redin/render.odin:1346-1360` (caller in `draw_text`)

`layout` and `draw` accept a per-block size resolver. The renderer (in `render.odin`) builds it from the theme map and a hardcoded scale table.

- [ ] **Step 1: Add a helper to resolve per-block font params.** Add to top of `src/redin/markdown/render.odin` (after the imports, before `Span_Box`):

```odin
// Per-block render parameters resolved by the caller from the theme map.
// One entry per Block; blocks[i] uses entries[i].
Block_Params :: struct {
	font_size:   f32,
	line_height: f32,    // ratio
}
```

- [ ] **Step 2: Make `layout` take per-block params.** Apply these targeted edits to the existing `layout` proc in `src/redin/markdown/render.odin` — DO NOT rewrite the whole proc; preserve the existing word-wrap logic byte-for-byte. The four edits:

1. Signature: replace `base_font_size: f32, line_height_ratio: f32, max_width: f32,` with `params: []Block_Params, max_width: f32,`.
2. Inside the outer `for blk in blocks` loop: change `for blk in blocks` to `for blk, blk_idx in blocks` and add `bp := params[blk_idx]` as the first line of the loop.
3. Inside the loop: change `lh := text_pkg.line_height(base_font_size, line_height_ratio)` (currently above the loop) to be **inside** the loop using `bp.font_size, bp.line_height`.
4. Inside the loop: every `emit(...)` call's `base_font_size` argument becomes `bp.font_size`, every `lh` argument stays as the now-loop-local `lh`.

- [ ] **Step 3: Replace `draw` to take per-block params.** Same pattern in the `draw` proc (lines 143–166 of `src/redin/markdown/render.odin`):

1. Signature: replace `base_font_size: f32, base_font_name: string, line_height_ratio: f32` with `params: []Block_Params, base_font_name: string`.
2. Inside `for blk, blk_idx in laid`: add `bp := params[blk_idx]` as the first line.
3. Replace `lh := text_pkg.line_height(base_font_size, line_height_ratio)` (currently above the loop) with a per-block `lh := text_pkg.line_height(bp.font_size, bp.line_height)` inside the loop.
4. The `rl.DrawTextEx(fnt, cstr, rl.Vector2{x, y}, base_font_size, 0, color)` call becomes `rl.DrawTextEx(fnt, cstr, rl.Vector2{x, y}, bp.font_size, 0, color)`.
5. The `block_y_offset += lh` paragraph-spacing line outside the inner loop continues to use the current block's `lh` (compute it once at top of outer loop and reuse).

- [ ] **Step 4: Update caller in `src/redin/render.odin` `draw_text`.** Replace the markdown branch (lines 1349–1356) with:

```odin
if n.markdown {
	blocks := markdown.parse(n.content, context.temp_allocator)
	params := build_markdown_params(blocks, theme, n.aspect, font_size, lh_ratio, context.temp_allocator)
	laid := markdown.layout(blocks, params, font_name, rect.width, context.temp_allocator)
	markdown.draw(laid, rect, text_color, params, font_name)
	return
}
```

…and add `build_markdown_params` just above `draw_text` (in `src/redin/render.odin`):

```odin
// Resolve per-block font params for a markdown text node. Headings consult
// :h1..:h6 aspects; missing aspects use a hardcoded scale table.
build_markdown_params :: proc(
	blocks: []markdown.Block,
	theme: map[string]types.Theme,
	host_aspect: string,
	base_font_size: f32,
	base_lh: f32,
	allocator := context.allocator,
) -> []markdown.Block_Params {
	context.allocator = allocator
	heading_scale := [6]f32{2.0, 1.7, 1.4, 1.2, 1.1, 1.0}
	out := make([]markdown.Block_Params, len(blocks))
	for blk, idx in blocks {
		size := base_font_size
		lh := base_lh
		if blk.kind == .Heading {
			level := int(blk.level)
			if level < 1 do level = 1
			if level > 6 do level = 6
			// Aspect lookup: :h<level> overrides scale-only fallback.
			h_key := fmt.tprintf("h%d", level)
			if h, ok := theme[h_key]; ok {
				if h.font_size > 0 do size = f32(h.font_size)
				if h.line_height > 0 do lh = h.line_height
			} else {
				size = base_font_size * heading_scale[level - 1]
			}
		}
		out[idx] = markdown.Block_Params{font_size = size, line_height = lh}
	}
	return out
}
```

- [ ] **Step 5: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build. The new caller wires the heading scale through; paragraphs continue to use base_font_size/lh.

- [ ] **Step 6: Smoke test** by running the existing markdown test app.

```bash
./build/redin --dev test/ui/markdown_app.fnl > /tmp/md.log 2>&1 &
SPID=$!
until [ -f .redin-port ]; do sleep 0.2; done
curl -s -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/frames | head -c 200
echo
curl -s -H "Authorization: Bearer $(cat .redin-token)" -X POST http://localhost:$(cat .redin-port)/shutdown
wait $SPID 2>/dev/null
rm -f .redin-port .redin-token
```

Expected: server exits cleanly, frames JSON includes the markdown text node, no crash.

- [ ] **Step 7: Commit.**

```bash
git add src/redin/markdown/render.odin src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(markdown): per-block heading sizing

layout/draw now take a Block_Params slice (one entry per block). The
renderer in src/redin/render.odin resolves it from the theme map: for
heading blocks it looks up :h<level> and falls back to a scale table
(2.0, 1.7, 1.4, 1.2, 1.1, 1.0) when the aspect is absent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `Style_Override` on Theme + bridge parsing

**Files:**
- Modify: `src/redin/types/theme.odin` (add `Style_Override` + 3 fields)
- Modify: `src/redin/bridge/bridge.odin` (`lua_to_theme` parses sub-tables)

The `Theme` struct grows three optional sub-overrides. The bridge parses three new sub-tables in `set-theme`.

- [ ] **Step 1: Add `Style_Override` and Theme fields.** In `src/redin/types/theme.odin`, after the `Shadow` declaration:

```odin
Style_Override :: struct {
	color: [3]u8,    // (0,0,0) → inherit unless `set` is true
	bg:    [4]u8,    // (0,0,0,0) → inherit; meaningful only for code
	set:   bool,     // explicit "this sub-table was provided"
}
```

Then add three fields at the bottom of `Theme`:

```odin
Theme :: struct {
	bg:           [3]u8,
	color:        [3]u8,
	padding:      [4]u8,
	border:       [3]u8,
	border_width: u8,
	radius:       u8,
	weight:       u8,
	text_align:   Text_Align,
	font_size:    f16,
	line_height:  f32,
	font:         string,
	opacity:      f32,
	shadow:       Shadow,
	selection:    [4]u8,
	bold:         Style_Override,
	italic:       Style_Override,
	code:         Style_Override,
}
```

- [ ] **Step 2: Add `lua_get_style_override` helper.** In `src/redin/bridge/bridge.odin`, after `lua_get_shadow_field`:

```odin
lua_get_style_override :: proc(L: ^Lua_State, index: i32, field: cstring) -> types.Style_Override {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}
	abs := lua_gettop(L)
	out: types.Style_Override
	out.set = true
	out.color = lua_get_rgb_field(L, abs, "color")
	out.bg = lua_get_rgba_field(L, abs, "bg")
	return out
}
```

- [ ] **Step 3: Parse the three sub-tables in `lua_to_theme`.** In `src/redin/bridge/bridge.odin`, immediately after the existing `t.selection = lua_get_rgba_field(L, props_idx, "selection")` line:

```odin
t.bold   = lua_get_style_override(L, props_idx, "bold")
t.italic = lua_get_style_override(L, props_idx, "italic")
t.code   = lua_get_style_override(L, props_idx, "code")
```

- [ ] **Step 4: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build. (Renderer doesn't read the new fields yet — Task 6 wires that.)

- [ ] **Step 5: Smoke test** that the dev server still starts under a theme containing the new sub-tables (round-trip parsing only — no rendering effect yet):

```bash
cat > /tmp/md_smoke.fnl <<'EOF'
(local theme-mod (require :theme))
(theme-mod.set-theme
  {:body {:font-size 14 :color [216 222 233]
          :bold {:color [255 255 255]}
          :code {:bg [40 40 50] :color [220 220 220]}}})
(global main_view (fn [] [:vbox {:aspect :body} [:text {} "ok"]]))
EOF
./build/redin --dev /tmp/md_smoke.fnl > /tmp/smoke.log 2>&1 &
SPID=$!
until [ -f .redin-port ]; do sleep 0.2; done
curl -s -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/aspects | head -c 300
echo
curl -s -H "Authorization: Bearer $(cat .redin-token)" -X POST http://localhost:$(cat .redin-port)/shutdown
wait $SPID 2>/dev/null
rm -f .redin-port .redin-token /tmp/md_smoke.fnl
```

Expected: JSON contains the body aspect; the binary doesn't crash on the nested tables.

- [ ] **Step 6: Commit.**

```bash
git add src/redin/types/theme.odin src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(theme): :bold / :italic / :code style override sub-tables

Theme entries gain three optional sub-overrides for color (and bg on
:code). lua_to_theme parses them via a new lua_get_style_override
helper. Renderer wiring lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Renderer reads style overrides

**Files:**
- Modify: `src/redin/markdown/render.odin:143-166` (`draw` — accept Style_Theme)
- Modify: `src/redin/render.odin:1349-1360` (`draw_text` markdown branch — build Style_Theme)

`markdown.draw` reads colors from a `Style_Theme` struct passed by the caller. The caller resolves it from the host aspect's overrides.

- [ ] **Step 1: Add `Style_Theme` to markdown package.** Near the top of `src/redin/markdown/render.odin`:

```odin
// Resolved per-style colors. Caller fills this from the host aspect's
// :bold / :italic / :code sub-tables (with parent fallbacks).
Style_Theme :: struct {
	base_color:   rl.Color,
	bold_color:   rl.Color,
	italic_color: rl.Color,
	code_color:   rl.Color,
	code_bg:      rl.Color,
}
```

- [ ] **Step 2: Update `draw` to take a Style_Theme.** Change the `draw` signature and color/bg reads:

1. Signature: drop the `color: rl.Color` parameter; add `style: Style_Theme`. Resulting prototype:

   ```odin
   draw :: proc(laid: []Laid_Block, rect: rl.Rectangle, style: Style_Theme, params: []Block_Params, base_font_name: string)
   ```

2. Inside the inner span loop, replace the literal `code_bg := rl.Color{60, 60, 70, 255}` block. Use `style.code_bg` for the rectangle and pick the text color via:

   ```odin
   span_color: rl.Color
   switch span.style {
   case .Regular:                                span_color = style.base_color
   case .Bold, .Bold_Italic:                     span_color = style.bold_color
   case .Italic:                                 span_color = style.italic_color
   case .Code:                                   span_color = style.code_color
   }
   ```

3. The `if span.style == .Code` rectangle uses `style.code_bg` directly; remove the local `code_bg` variable.

4. The `rl.DrawTextEx(..., color)` call uses `span_color` instead.

- [ ] **Step 3: Build a Style_Theme in `draw_text`.** In `src/redin/render.odin`, replace the markdown branch (Task 4 left it at):

```odin
if n.markdown {
	blocks := markdown.parse(n.content, context.temp_allocator)
	params := build_markdown_params(blocks, theme, n.aspect, font_size, lh_ratio, context.temp_allocator)
	laid := markdown.layout(blocks, params, font_name, rect.width, context.temp_allocator)
	markdown.draw(laid, rect, text_color, params, font_name)
	return
}
```

with:

```odin
if n.markdown {
	blocks := markdown.parse(n.content, context.temp_allocator)
	params := build_markdown_params(blocks, theme, n.aspect, font_size, lh_ratio, context.temp_allocator)
	style := build_markdown_style(theme, n.aspect, text_color)
	laid := markdown.layout(blocks, params, font_name, rect.width, context.temp_allocator)
	markdown.draw(laid, rect, style, params, font_name)
	return
}
```

…and add `build_markdown_style` near `build_markdown_params`:

```odin
// Resolve markdown per-style colors from the host aspect's overrides.
// Defaults: base_color = the text color the caller already computed;
// bold/italic/code colors fall back to base_color when not set; code_bg
// falls back to {60, 60, 70, 255}.
build_markdown_style :: proc(
	theme: map[string]types.Theme,
	host_aspect: string,
	base_color: rl.Color,
) -> markdown.Style_Theme {
	out := markdown.Style_Theme{
		base_color   = base_color,
		bold_color   = base_color,
		italic_color = base_color,
		code_color   = base_color,
		code_bg      = rl.Color{60, 60, 70, 255},
	}
	host, ok := theme[host_aspect]
	if !ok do return out
	if host.bold.set && (host.bold.color != [3]u8{}) {
		out.bold_color = rl.Color{host.bold.color[0], host.bold.color[1], host.bold.color[2], 255}
	}
	if host.italic.set && (host.italic.color != [3]u8{}) {
		out.italic_color = rl.Color{host.italic.color[0], host.italic.color[1], host.italic.color[2], 255}
	}
	if host.code.set {
		if host.code.color != [3]u8{} {
			out.code_color = rl.Color{host.code.color[0], host.code.color[1], host.code.color[2], 255}
		}
		// {0,0,0,0} → inherit; non-zero alpha → explicit bg.
		if host.code.bg[3] != 0 || (host.code.bg[0] | host.code.bg[1] | host.code.bg[2]) != 0 {
			out.code_bg = rl.Color{host.code.bg[0], host.code.bg[1], host.code.bg[2], host.code.bg[3]}
		}
	}
	return out
}
```

- [ ] **Step 4: Build host binary.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build.

- [ ] **Step 5: Run existing markdown test to make sure nothing regressed.**

```bash
./build/redin --dev test/ui/markdown_app.fnl > /tmp/md.log 2>&1 &
SPID=$!
until [ -f .redin-port ]; do sleep 0.2; done
bb test/ui/run.bb test/ui/test_markdown.bb 2>&1 | tail -5
curl -s -H "Authorization: Bearer $(cat .redin-token)" -X POST http://localhost:$(cat .redin-port)/shutdown
wait $SPID 2>/dev/null
rm -f .redin-port .redin-token
```

Expected: existing markdown tests pass.

- [ ] **Step 6: Commit.**

```bash
git add src/redin/markdown/render.odin src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(markdown): per-style theme overrides in draw

markdown.draw now takes a Style_Theme that the renderer fills from the
host aspect's :bold / :italic / :code sub-tables. Bold_Italic uses the
bold color (closest structural match). Code background falls back to
{60, 60, 70, 255} when the host aspect has no :code :bg.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: UI test extension

**Files:**
- Modify: `test/ui/markdown_app.fnl` (add heading + nested + override sample)
- Modify: `test/ui/test_markdown.bb` (assert rendering)

- [ ] **Step 1: Read current test fixture.**

```bash
cat test/ui/markdown_app.fnl test/ui/test_markdown.bb
```

Note the existing structure so the additions follow the same pattern.

- [ ] **Step 2: Replace `test/ui/markdown_app.fnl` with an extended sample.** Keep any existing sample(s) intact; add a new node with id `:md-extended`. Concrete content (adjust for the existing structure — keep the existing `:md` node if there is one):

```fennel
(local theme-mod (require :theme))
(local dataflow (require :dataflow))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]
             :bold   {:color [255 255 255]}
             :italic {:color [180 180 220]}
             :code   {:bg [40 40 50] :color [220 220 220]}}
   :h1      {:font-size 28 :weight 1 :color [236 239 244]}
   :h2      {:font-size 22 :weight 1 :color [236 239 244]}})

(dataflow.init {})

(global main_view
  (fn []
    [:vbox {:aspect :surface}
     [:text {:id :md-extended :aspect :body :markdown true}
      "# Heading 1

       ## Heading 2

       Plain paragraph with **bold _and italic_** plus `code`."]]))
```

(If `markdown_app.fnl` already wires a different state shape, adapt — what matters is one `[:text {:id :md-extended :aspect :body :markdown true} ...]` in the rendered tree.)

- [ ] **Step 3: Append assertions to `test/ui/test_markdown.bb`.** After existing tests:

```clojure
(deftest md-extended-renders
  (let [el (find-element {:id :md-extended})]
    (assert el "md-extended must exist in /frames")
    (let [r (rect-of el)]
      (assert r "md-extended must have a :rect")
      ;; Heading + heading + paragraph at base_font_size 14 ≈ at least 50px tall.
      (assert (>= (:h r) 50)
              (str "md-extended rect height should be >= 50, got " (:h r))))))
```

- [ ] **Step 4: Run the UI test.**

```bash
./build/redin --dev test/ui/markdown_app.fnl > /tmp/md.log 2>&1 &
SPID=$!
until [ -f .redin-port ]; do sleep 0.2; done
bb test/ui/run.bb test/ui/test_markdown.bb 2>&1 | tail -10
curl -s -H "Authorization: Bearer $(cat .redin-token)" -X POST http://localhost:$(cat .redin-port)/shutdown
wait $SPID 2>/dev/null
rm -f .redin-port .redin-token
```

Expected: all markdown UI tests pass, including the new `md-extended-renders`.

- [ ] **Step 5: Commit.**

```bash
git add test/ui/markdown_app.fnl test/ui/test_markdown.bb
git commit -m "$(cat <<'EOF'
test(ui): markdown — heading + nested-style + theme override sample

Adds :md-extended exercising headings (:h1, :h2), nested **bold _italic_**,
and :body :bold/:italic/:code overrides. Asserts the node appears in
/frames with a sensibly tall rect.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Docs

**Files:**
- Modify: `docs/core-api.md` (one bullet)
- Modify: `docs/reference/theme.md` (sub-tables + heading aspects)

- [ ] **Step 1: Find the `:markdown` line in core-api.md.**

```bash
grep -n "markdown" docs/core-api.md | head
```

- [ ] **Step 2: Append a sentence to that paragraph.** Edit `docs/core-api.md` so the `:markdown` description ends with:

> v1.1 also supports headings (`#`–`######`), nested emphasis (`**bold _italic_**`), and per-style theme overrides (`:bold` / `:italic` / `:code` sub-tables under each aspect).

- [ ] **Step 3: Document sub-tables in theme.md.** Append a new subsection to `docs/reference/theme.md`:

```markdown
### Markdown style overrides

Aspects consumed by `:text {:markdown true}` accept three optional
sub-tables that override per-style rendering:

```fennel
{:body {:font-size 14 :color [216 222 233]
        :bold   {:color [255 255 255]}
        :italic {:color [180 180 220]}
        :code   {:bg [40 40 50] :color [220 220 220]}}}
```

- `:bold` and `:italic` only honor `:color`.
- `:code` honors `:color` and `:bg`. The default code background (when
  unset) is `[60 60 70 255]`.
- `Bold_Italic` spans (e.g. `**bold _italic_**`) use the `:bold`
  override; a separate sub-table can be added later if needed.

#### Heading aspects

Headings rendered from markdown look up `:h1`–`:h6`. Each entry honors
`:font-size`, `:color`, `:weight`, and `:line-height`, with non-zero
fields overriding the host aspect. When `:h<N>` is absent, the heading
font size is the host aspect's `:font-size` × a level scale of
`{2.0, 1.7, 1.4, 1.2, 1.1, 1.0}`.
```

- [ ] **Step 4: Sanity-check the markdown renders.**

```bash
sed -n '/Markdown style overrides/,/Heading aspects/p' docs/reference/theme.md | head -30
```

Expected: the new section is present and well-formed.

- [ ] **Step 5: Commit.**

```bash
git add docs/core-api.md docs/reference/theme.md
git commit -m "$(cat <<'EOF'
docs: markdown — headings, nested emphasis, per-style overrides

Documents the new :markdown features and the :h1..:h6 / :bold / :italic
/ :code theme schema added in #105.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

After all 8 tasks:

- [ ] **Build:**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

- [ ] **Parser tests:**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Runtime tests:**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

- [ ] **Full UI suite (windowed):**

```bash
bash test/ui/run-all.sh
```

- [ ] **Full UI suite (headless):**

```bash
bash test/ui/run-all.sh --headless
```

- [ ] **REDIN_AGENT build + suite:**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin
bash test/ui/run-all.sh --headless
```

All must pass. Then push the branch and open a PR titled `feat(markdown): headings, nested styles, per-style theme overrides (closes #105)`.
