# Markdown-as-nodes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the dedicated `:text {:markdown true}` render pipeline with a `[:markdown]` element that lowers to a regular subtree of `:vbox` / `:hbox` / `:text` nodes during bridge node-reading. Inline emphasis stays inside one `:text` node, carried as `inline_spans`. Block structure (paragraphs, headings, list items, lists) becomes regular nodes themed with `md/*` aspects from a new `default-theme` fallback layer.

**Architecture:** The bridge's `lua_flatten_node` dispatches on tag — when it sees `:markdown`, it calls `markdown.parse` (extended with heading + list blocks) → `markdown.lower` (returns a `LoweredTree` of synthetic `Node` values) → `bridge.flatten_subtree` (DFS-walks the synthetic tree into the bridge's flat arrays the same way Lua tables are flattened). Inline spans on `NodeText` are rendered via a new `text.span_layout_and_draw` (lifted from the old `markdown.layout` + `markdown.draw`).

**Tech Stack:** Odin (host), LuaJIT/Fennel (runtime), Raylib (renderer), Babashka (UI integration tests).

**Reference docs:**
- Spec: `docs/superpowers/specs/2026-05-02-markdown-as-nodes-design.md`
- Project conventions: `CLAUDE.md`, `.claude/skills/redin-dev/SKILL.md`, `.claude/skills/redin-maintenance/SKILL.md`
- Build: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
- Odin tests: `odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1`
- Fennel tests: `luajit test/lua/runner.lua test/lua/test_*.fnl`
- UI tests: `bash test/ui/run-all.sh --headless`

**Branch:** `feat/markdown-nodes` (already created, branched from `main`).

**Commit style:** Conventional commits (`feat(scope): …`, `refactor(scope): …`, `docs(scope): …`, `test(scope): …`).

---

## Task 1: Move `Span` / `Span_Style` types to the `text` package

**Why:** The text renderer is going to consume spans (mixed-font wrap), so the type belongs to `text`, not `markdown`. After this move, the dependency direction is `markdown → text` for the type, and later `render → text` for the layout/draw.

**Files:**
- Create: `src/redin/text/spans.odin`
- Modify: `src/redin/markdown/parser.odin` (drop the type defs, import `text`, re-export aliases at package level so `parser_test.odin` and `render.odin` keep compiling without changes)

- [ ] **Step 1: Create `src/redin/text/spans.odin`** with the `Span` + `Span_Style` types lifted verbatim from `parser.odin`.

```odin
package text

// Inline-span style. Drives font/face selection and code-bg fill in the
// span-aware text renderer.
Span_Style :: enum u8 { Regular, Bold, Italic, Code }

// One inline span: a contiguous run of text rendered in a single style.
// Produced by the markdown parser; consumed by the text package's
// span-aware layout/draw and stored on `NodeText.inline_spans`.
Span :: struct {
	style: Span_Style,
	text:  string,
}
```

- [ ] **Step 2: Verify build still passes** before any markdown edits.

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success. (Two definitions of `Span` exist transiently — markdown's own and text's — but they're in different packages, so no collision.)

- [ ] **Step 3: In `src/redin/markdown/parser.odin`, replace the type defs with an import of `text`.**

Find the existing block (around line 5):
```odin
Span_Style :: enum u8 { Regular, Bold, Italic, Code }

Span :: struct {
	style: Span_Style,
	text:  string,
}
```

Replace with:
```odin
import text_pkg "../text"

Span :: text_pkg.Span
Span_Style :: text_pkg.Span_Style
```

Add the import next to the existing `import "core:strings"`.

- [ ] **Step 4: Build to confirm `markdown` now resolves `Span` via `text`.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success.

- [ ] **Step 5: Run the parser tests to confirm types still match.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: all existing tests pass (the aliases `Span` / `Span_Style` keep `parser_test.odin` source compatible).

- [ ] **Step 6: Commit.**

```bash
git add src/redin/text/spans.odin src/redin/markdown/parser.odin
git commit -m "$(cat <<'EOF'
refactor(text): move Span types from markdown to text package

The span-aware text renderer (next step) belongs to the text
package, so the Span / Span_Style types move with it. markdown
keeps source-compatible aliases via package import.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `text.span_layout_and_draw`

**Why:** Today's `markdown.layout` + `markdown.draw` is a span-aware mixed-font wrap renderer. We want it as a public `text` package API so any text node can use it, gated by `inline_spans` presence.

**Files:**
- Create: `src/redin/text/span_layout.odin`
- Create: `src/redin/text/span_layout_test.odin`

- [ ] **Step 1: Create `src/redin/text/span_layout.odin`** with the function below. It generalises the old `markdown.layout` + `markdown.draw` to take base font/size/color/lh from caller-resolved aspect values, plus an optional `code_aspect` resolved-properties map for inline-code styling.

```odin
package text

import "core:strings"
import "../font"
import rl "vendor:raylib"

// Style overrides for inline code spans. Resolved from the :md/code
// aspect by the caller and passed in. Zero-value fields fall back to
// hardcoded defaults compatible with the old markdown render path.
Span_Code_Style :: struct {
	font_name:        string,         // empty -> "mono"
	bg:               [3]u8,          // {0,0,0} -> {60,60,70}
	color:            [3]u8,          // {0,0,0} -> use base text_color
	color_set:        bool,
}

// Layout-and-draw a list of inline spans inside `rect` using mixed
// fonts derived from `base_font_name` + per-span style.
//
// Greedy word wrap respects whitespace boundaries within each span;
// soft line breaks ('\n' inside a span's text) force a wrap.
//
// Allocations live in `context.temp_allocator`.
span_layout_and_draw :: proc(
	spans:             []Span,
	rect:              rl.Rectangle,
	base_font_name:    string,
	base_font_size:    f32,
	line_height_ratio: f32,
	text_color:        rl.Color,
	code_style:        Span_Code_Style,
) {
	if len(spans) == 0 do return

	lh := line_height(base_font_size, line_height_ratio)

	code_font_name := code_style.font_name
	if len(code_font_name) == 0 do code_font_name = "mono"
	code_bg := code_style.bg
	if code_bg == [3]u8{0,0,0} do code_bg = [3]u8{60,60,70}

	cursor_x: f32 = 0
	cursor_y: f32 = 0
	first_unit_on_line := true

	font_for :: proc(style: Span_Style, base_name, code_name: string) -> rl.Font {
		switch style {
		case .Regular: return font.get(base_name, .Regular)
		case .Bold:    return font.get(base_name, .Bold)
		case .Italic:  return font.get(base_name, .Italic)
		case .Code:    return font.get(code_name, .Regular)
		}
		return font.get(base_name, .Regular)
	}

	color_for :: proc(style: Span_Style, base: rl.Color, cs: Span_Code_Style) -> rl.Color {
		if style == .Code && cs.color_set {
			return rl.Color{cs.color[0], cs.color[1], cs.color[2], 255}
		}
		return base
	}

	emit :: proc(style: Span_Style, text: string,
	             rect: rl.Rectangle, lh: f32,
	             base_font_name, code_font_name: string,
	             base_font_size: f32, text_color: rl.Color,
	             code_style: Span_Code_Style, code_bg: [3]u8,
	             cursor_x: ^f32, cursor_y: ^f32, first_unit_on_line: ^bool) {
		if len(text) == 0 do return
		fnt := font_for(style, base_font_name, code_font_name)
		cstr := strings.clone_to_cstring(text, context.temp_allocator)
		size := rl.MeasureTextEx(fnt, cstr, base_font_size, 0)
		w := size.x

		if !first_unit_on_line^ && cursor_x^ + w > rect.width {
			cursor_x^ = 0
			cursor_y^ += lh
			first_unit_on_line^ = true
		}
		x := rect.x + cursor_x^
		y := rect.y + cursor_y^

		if style == .Code {
			rl.DrawRectangleRec(
				rl.Rectangle{x, y, w, lh},
				rl.Color{code_bg[0], code_bg[1], code_bg[2], 255})
		}
		col := color_for(style, text_color, code_style)
		rl.DrawTextEx(fnt, cstr, rl.Vector2{x, y}, base_font_size, 0, col)

		cursor_x^ += w
		first_unit_on_line^ = false
	}

	for span in spans {
		s := span.text
		start := 0
		i := 0
		for i < len(s) {
			ch := s[i]
			if ch == '\n' {
				if i > start {
					emit(span.style, s[start:i], rect, lh,
						base_font_name, code_font_name,
						base_font_size, text_color,
						code_style, code_bg,
						&cursor_x, &cursor_y, &first_unit_on_line)
				}
				cursor_x = 0
				cursor_y += lh
				first_unit_on_line = true
				i += 1
				start = i
				continue
			}
			if ch == ' ' || ch == '\t' {
				if i > start {
					emit(span.style, s[start:i], rect, lh,
						base_font_name, code_font_name,
						base_font_size, text_color,
						code_style, code_bg,
						&cursor_x, &cursor_y, &first_unit_on_line)
				}
				ws := s[i:i+1]
				i += 1
				if first_unit_on_line {
					start = i
					continue
				}
				emit(span.style, ws, rect, lh,
					base_font_name, code_font_name,
					base_font_size, text_color,
					code_style, code_bg,
					&cursor_x, &cursor_y, &first_unit_on_line)
				start = i
				continue
			}
			i += 1
		}
		if start < len(s) {
			emit(span.style, s[start:], rect, lh,
				base_font_name, code_font_name,
				base_font_size, text_color,
				code_style, code_bg,
				&cursor_x, &cursor_y, &first_unit_on_line)
		}
	}
}
```

- [ ] **Step 2: Create `src/redin/text/span_layout_test.odin`** with one smoke test that verifies the function compiles and runs without crashing on a small input. (Visual correctness is covered by the UI integration test; this is just a build-time guard.)

```odin
package text

import "core:testing"
import rl "vendor:raylib"

@(test)
test_span_layout_smoke :: proc(t: ^testing.T) {
	// Smoke test: function must run without crashing on a small input.
	// We can't assert pixel output without a GL context, so this is
	// purely a compile-time / no-panic guard.
	spans := []Span{
		{style = .Regular, text = "hello "},
		{style = .Bold,    text = "world"},
	}
	span_layout_and_draw(
		spans,
		rl.Rectangle{0, 0, 100, 50},
		"sans",
		16,
		1.5,
		rl.Color{0, 0, 0, 255},
		Span_Code_Style{},
	)
	testing.expect(t, true)
}
```

- [ ] **Step 3: Build.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success.

- [ ] **Step 4: Commit.**

```bash
git add src/redin/text/span_layout.odin src/redin/text/span_layout_test.odin
git commit -m "$(cat <<'EOF'
feat(text): span_layout_and_draw — mixed-font inline wrap

Lifts the old markdown.layout + markdown.draw into the text
package as a generic span renderer. Takes a base font/size/colour
plus an optional code-style override; zero-value fields fall back
to defaults compatible with today's markdown rendering. Will be
called from render.draw_text when NodeText.inline_spans is set.

The old markdown.layout + markdown.draw stay in place for now;
they'll be deleted after the new pipeline is fully wired.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `NodeText.inline_spans` field

**Why:** The bridge needs a place to attach pre-parsed spans on text nodes emitted by markdown lowering. The render branches on this field's presence.

**Files:**
- Modify: `src/redin/types/view_tree.odin`

- [ ] **Step 1: Add the field to `NodeText`.**

In `src/redin/types/view_tree.odin`, find the `NodeText` struct (around line 175). After `markdown: bool,` add:

```odin
	inline_spans:   []text.Span,   // nil = plain rendering, non-nil = mixed-font wrap
```

Add the import at the top of the file alongside the existing imports:

```odin
import "../text"
```

- [ ] **Step 2: Build.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success. The field is unused anywhere yet; this is a structural change only.

- [ ] **Step 3: Commit.**

```bash
git add src/redin/types/view_tree.odin
git commit -m "$(cat <<'EOF'
feat(types): NodeText.inline_spans

Storage for pre-parsed inline spans on text nodes. nil means plain
rendering. Will be populated by the markdown lowering step and
consumed by render.draw_text.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Default-theme fallback layer in `theme.fnl`

**Why:** Markdown lowering produces nodes with `:md/*` aspects. The framework needs to ship sensible defaults that the user's `theme.set-theme` can override. A separate `default-theme` map (looked up *after* the user's theme) prevents the user's theme replacement from clobbering markdown defaults.

**Files:**
- Modify: `src/runtime/theme.fnl`
- Modify: `test/lua/test_theme.fnl`

- [ ] **Step 1: Read the existing test file** to understand the test framework conventions.

Run:
```bash
cat test/lua/test_theme.fnl
```

Expected: a Fennel module with a `local t {}` table, named test functions, returning `t`. Tests use `assert`.

- [ ] **Step 2: Append a failing test to `test/lua/test_theme.fnl`** asserting default-theme fallback behaviour.

Add at the end of the file, before the final return:

```fennel
(fn t.test-default-theme-fallback []
  ;; Defaults visible when user-theme is empty.
  (theme.reset)
  (theme.set-defaults {:foo {:color [1 2 3]}})
  (let [resolved (theme.resolve :foo [])]
    (assert (= 1 (. resolved :color 1))))

  ;; User-theme overrides default at the aspect level.
  (theme.set-theme {:foo {:color [9 9 9]}})
  (let [resolved (theme.resolve :foo [])]
    (assert (= 9 (. resolved :color 1))))

  ;; Aspect missing in user-theme falls through to defaults.
  (theme.set-theme {})
  (theme.set-defaults {:bar {:color [5 5 5]}})
  (let [resolved (theme.resolve :bar [])]
    (assert (= 5 (. resolved :color 1)))))
```

- [ ] **Step 3: Run tests to confirm the new test fails.**

Run:
```bash
luajit test/lua/runner.lua test/lua/test_theme.fnl
```

Expected: failure on `test-default-theme-fallback`, with an error like "attempt to call nil value (field 'set-defaults')" or similar — the function doesn't exist yet.

- [ ] **Step 4: Implement the fallback layer in `src/runtime/theme.fnl`.**

Near the top of the file, alongside `(var theme-table {})`, add:

```fennel
(var default-theme-table {})
```

After the `(fn M.set-theme ...)` definition, add:

```fennel
(fn M.set-defaults [t]
  (set default-theme-table t))
```

Modify `(fn M.reset ...)` to also reset defaults:

```fennel
(fn M.reset []
  (set theme-table {})
  (set default-theme-table {}))
```

Modify `(fn M.resolve [aspect states])` so the per-aspect lookup falls back to defaults when the user theme has no entry. In the simple-keyword branch, change:

```fennel
    (do
      (var props (or (. theme-table aspect) {}))
```

to:

```fennel
    (do
      (var props (or (. theme-table aspect)
                     (. default-theme-table aspect)
                     {}))
```

In the table-of-keys branch, change the inner aspect lookup from:

```fennel
      (each [_ key (ipairs aspect)]
        (let [base (or (. theme-table key) {})]
          (set props (shallow-merge props base))))
```

to:

```fennel
      (each [_ key (ipairs aspect)]
        (let [base (or (. theme-table key)
                       (. default-theme-table key)
                       {})]
          (set props (shallow-merge props base))))
```

State variants (`aspect#state`) continue to come from `theme-table` only. Defaults are aspect-level only — apps customise hover/active/focus themselves.

- [ ] **Step 5: Run the test to confirm pass.**

Run:
```bash
luajit test/lua/runner.lua test/lua/test_theme.fnl
```

Expected: all tests in `test_theme.fnl` pass, including the new one.

- [ ] **Step 6: Run the full Fennel suite to confirm no regression.**

Run:
```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: all tests pass.

- [ ] **Step 7: Commit.**

```bash
git add src/runtime/theme.fnl test/lua/test_theme.fnl
git commit -m "$(cat <<'EOF'
feat(theme): default-theme fallback layer

Aspect lookup now falls back: user-theme → default-theme → empty.
default-theme is set via theme.set-defaults — distinct from
set-theme so the user's app-level theme replacement doesn't
clobber framework-shipped defaults. State variants (aspect#state)
remain user-theme-only.

Will host the framework's :md/* defaults next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Register `md/*` defaults in default-theme

**Why:** Apps using `[:markdown]` should render readable markdown out of the box, without any theme config. Defaults live in the runtime so they're hot-reload friendly and inspectable.

**Files:**
- Create: `src/runtime/markdown.fnl`
- Modify: `src/runtime/init.fnl` (require + call set-defaults at startup)
- Modify: `test/lua/test_theme.fnl` (one assertion that defaults are registered after init)

- [ ] **Step 1: Read `src/runtime/init.fnl`** to find the right place to wire startup defaults.

Run:
```bash
cat src/runtime/init.fnl
```

Note the existing `require` calls and where they sit. The markdown defaults call should land after `theme` is required, before user app code loads.

- [ ] **Step 2: Create `src/runtime/markdown.fnl`** with the default theme map.

```fennel
;; markdown.fnl -- Default theme entries for the `:md/*` aspect family.
;; Registered into theme.set-defaults at runtime startup so apps using
;; [:markdown] render legibly without any theme config.

(local theme (require :theme))

(local M {})

(local defaults
  {;; Body text: paragraphs and list-item content.
   :md/body         {:font :sans :font-size 18 :color [240 240 240] :line-height 1.5}

   ;; Headings — descending size, bold for h1-h4, italic for h5/h6.
   :md/h1           {:font :sans :font-size 32 :color [240 240 240] :weight :bold :line-height 1.3}
   :md/h2           {:font :sans :font-size 26 :color [240 240 240] :weight :bold :line-height 1.3}
   :md/h3           {:font :sans :font-size 22 :color [240 240 240] :weight :bold :line-height 1.3}
   :md/h4           {:font :sans :font-size 19 :color [240 240 240] :weight :bold :line-height 1.4}
   :md/h5           {:font :sans :font-size 17 :color [240 240 240] :line-height 1.4}
   :md/h6           {:font :sans :font-size 16 :color [240 240 240] :line-height 1.4}

   ;; Lists.
   :md/list         {:padding [4 0 4 16]}
   :md/list-item    {:padding [2 0 2 0]}
   :md/list-marker  {:font :sans :font-size 18 :color [240 240 240] :line-height 1.5}

   ;; Inline code (read by span renderer; only font is consumed here —
   ;; bg / color come through resolve too if user overrides).
   :md/code         {:font :mono :font-size 16 :color [240 240 240] :bg [60 60 70]}})

(fn M.install []
  (theme.set-defaults defaults))

M
```

- [ ] **Step 3: Wire installation in `src/runtime/init.fnl`.**

Near the top of init.fnl, after `(local theme (require :theme))` (or whichever require loads theme), add:

```fennel
(local markdown-defaults (require :markdown))
(markdown-defaults.install)
```

(If a `markdown` Fennel module name collides with anything, rename to `md-defaults` and adjust the require accordingly.)

- [ ] **Step 4: Add an assertion in `test/lua/test_theme.fnl`** that `md/*` defaults are registered by init.

```fennel
(fn t.test-md-defaults-registered []
  ;; After init runs, the framework defaults should resolve.
  (let [resolved (theme.resolve :md/body [])]
    (assert (. resolved :font-size)
            "expected :md/body to have a default :font-size after init")))
```

(`init.fnl` runs at module load time, so the defaults should be present by the time tests execute. If your test runner resets state between tests, call `(let [_ (require :markdown)] ((. _ :install)))` at the top of the test to force re-installation.)

- [ ] **Step 5: Run all Fennel tests.**

Run:
```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: pass.

- [ ] **Step 6: Build to confirm Odin still compiles** (no Odin changes here, but the runtime files are bundled at build time).

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success.

- [ ] **Step 7: Commit.**

```bash
git add src/runtime/markdown.fnl src/runtime/init.fnl test/lua/test_theme.fnl
git commit -m "$(cat <<'EOF'
feat(runtime): :md/* default theme entries

Registers framework defaults for :md/body, :md/h1..h6, :md/list,
:md/list-item, :md/list-marker, :md/code via the new
theme.set-defaults fallback layer. Apps get readable markdown
without writing any theme; user theme.set-theme overrides
individual entries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Parser — heading blocks

**Why:** v1 scope includes `#` to `######`. Parser needs to recognise these at the start of a paragraph chunk and produce `Heading_N` blocks instead of `Paragraph`.

**Files:**
- Modify: `src/redin/markdown/parser.odin`
- Modify: `src/redin/markdown/parser_test.odin`

- [ ] **Step 1: Add a failing test** to `parser_test.odin`.

Append:

```odin
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
```

No additional imports needed — `Span_Style` is already exported as a package-level alias from `parser.odin` (added in Task 1).

- [ ] **Step 2: Run tests to confirm failure.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: compilation fails — `Heading_1` etc. are not defined yet.

- [ ] **Step 3: Extend `Block_Kind`** in `src/redin/markdown/parser.odin`.

Replace:

```odin
Block_Kind :: enum u8 { Paragraph }
```

with:

```odin
Block_Kind :: enum u8 {
	Paragraph,
	Heading_1, Heading_2, Heading_3, Heading_4, Heading_5, Heading_6,
}
```

- [ ] **Step 4: Add a heading detector** in the same file.

Add this helper proc somewhere in the file:

```odin
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
```

- [ ] **Step 5: Use the detector in `parse`** — change the loop body so heading-prefixed chunks become `Heading_N` blocks.

Replace the current loop:

```odin
	for p in paragraphs {
		spans := parse_inline(p)
		append(&blocks, Block{kind = .Paragraph, spans = spans})
	}
```

with:

```odin
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
		spans := parse_inline(p)
		append(&blocks, Block{kind = .Paragraph, spans = spans})
	}
```

- [ ] **Step 6: Run tests to confirm pass.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: all parser tests pass.

- [ ] **Step 7: Build the full binary** to ensure no downstream code broke on the new enum members.

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success. (`render.odin`'s `markdown.draw` handles only Paragraph today, but still works because Heading_N just changes block kind, not span shape — render iterates spans, which still exist on heading blocks.)

- [ ] **Step 8: Commit.**

```bash
git add src/redin/markdown/parser.odin src/redin/markdown/parser_test.odin
git commit -m "$(cat <<'EOF'
feat(markdown): heading block parsing

Parser now recognises ATX headings (`# `..`###### `) at the start of
a paragraph chunk and emits Heading_1..Heading_6 blocks. Inline
emphasis still parses inside heading content. Trailing hashes are
not stripped (treated as content); 7+ leading hashes or missing
space-after-hash falls back to paragraph.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Parser — list blocks

**Why:** v1 scope includes flat unordered + ordered lists. A list group is a contiguous run of lines starting (column 0) with `- `, `* `, or `<digit>+. `.

**Files:**
- Modify: `src/redin/markdown/parser.odin`
- Modify: `src/redin/markdown/parser_test.odin`

- [ ] **Step 1: Add failing tests** to `parser_test.odin`.

Append:

```odin
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
```

- [ ] **Step 2: Run tests to confirm failure.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: compilation fails — `List_Group`, `List_Item`, `items`, `ordered`, `marker` don't exist yet.

- [ ] **Step 3: Extend the `Block` struct + `Block_Kind` enum** in `parser.odin`.

Replace:

```odin
Block_Kind :: enum u8 {
	Paragraph,
	Heading_1, Heading_2, Heading_3, Heading_4, Heading_5, Heading_6,
}

Block :: struct {
	kind:  Block_Kind,
	spans: []Span,
}
```

with:

```odin
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
```

- [ ] **Step 4: Add a list-item detector and list-block parser.**

Add helpers near `detect_heading`:

```odin
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
```

- [ ] **Step 5: Wire list parsing into `parse`.**

Inside `parse`, when a paragraph chunk's first line begins with a list-item marker, treat the *whole chunk* as a list group: split by newline, parse each line as an item, combine into one `List_Group` block. (Recall `split_paragraphs` separates by blank line, so a list runs from start of chunk to end of chunk.)

Replace the current loop body in `parse`:

```odin
	for p in paragraphs {
		level, content_start := detect_heading(p)
		if level > 0 {
			...heading branch...
		}
		spans := parse_inline(p)
		append(&blocks, Block{kind = .Paragraph, spans = spans})
	}
```

with this expanded version (heading branch unchanged, list branch added before the paragraph fallback):

```odin
	for p in paragraphs {
		// Heading.
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
		first_kind, first_ord, _ := detect_list_item(first_line(p))
		if first_kind != 0 {
			items: [dynamic]Block
			ordered := first_ord
			lines := split_lines(p)
			for line in lines {
				k, _, cs := detect_list_item(line)
				if k == 0 {
					// Stray non-marker line in v1: drop or fold into prev item?
					// v1 strict: log and skip.
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

		// Paragraph.
		spans := parse_inline(p)
		append(&blocks, Block{kind = .Paragraph, spans = spans})
	}
```

Add the line-helper functions:

```odin
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
```

- [ ] **Step 6: Run tests to confirm pass.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: all parser tests pass.

- [ ] **Step 7: Build full binary.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success. (Adding new `Block_Kind` members may need `render.odin`'s switch on `blk.kind` — currently `markdown.layout` only inspects spans, not kind, so it should still build.)

- [ ] **Step 8: Commit.**

```bash
git add src/redin/markdown/parser.odin src/redin/markdown/parser_test.odin
git commit -m "$(cat <<'EOF'
feat(markdown): list block parsing

Parser recognises flat unordered (`-`, `*`) and ordered (`1.`)
list groups when markers appear at column 0. Each group becomes a
List_Group block with List_Item children carrying their own inline
spans + literal marker text. v1 strict: indented or
non-marker lines inside a list group are dropped (no continuations,
no nested lists).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `markdown.LoweredTree` + `markdown.lower`

**Why:** Core of the new pipeline: turn parsed `[]Block` into a synthetic node subtree the bridge can flatten. Single source of truth for "how does each block shape into nodes".

**Files:**
- Create: `src/redin/markdown/lower.odin`
- Create: `src/redin/markdown/lower_test.odin`

- [ ] **Step 1: Create `src/redin/markdown/lower_test.odin`** with failing tests for the LoweredTree shape.

```odin
package markdown

import "core:testing"
import "../types"
import text_pkg "../text"

@(test)
test_lower_single_paragraph :: proc(t: ^testing.T) {
	blocks := parse("hello world", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)

	// Wrapper vbox + one text child.
	testing.expect_value(t, len(tree.nodes), 2)
	_, ok := tree.nodes[0].(types.NodeVbox)
	testing.expect(t, ok, "root must be a vbox")
	tn, tok := tree.nodes[1].(types.NodeText)
	testing.expect(t, tok, "child must be a text node")
	testing.expect_value(t, tn.aspect, "md/body")
	testing.expect(t, len(tn.inline_spans) > 0, "inline_spans must be set")
	testing.expect_value(t, tree.parent_indices[0], -1)
	testing.expect_value(t, tree.parent_indices[1], 0)
}

@(test)
test_lower_heading_then_paragraph :: proc(t: ^testing.T) {
	blocks := parse("# Title\n\nA body.", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)

	// vbox + heading text + paragraph text.
	testing.expect_value(t, len(tree.nodes), 3)
	h, hok := tree.nodes[1].(types.NodeText)
	testing.expect(t, hok)
	testing.expect_value(t, h.aspect, "md/h1")
	p, pok := tree.nodes[2].(types.NodeText)
	testing.expect(t, pok)
	testing.expect_value(t, p.aspect, "md/body")
}

@(test)
test_lower_list :: proc(t: ^testing.T) {
	blocks := parse("- one\n- two", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)

	// Expected DFS order:
	//   0 wrapper vbox
	//   1 list vbox (:md/list)
	//   2 list-item hbox (:md/list-item)
	//   3 marker text (:md/list-marker)
	//   4 content text (:md/body)
	//   5 list-item hbox
	//   6 marker text
	//   7 content text
	testing.expect_value(t, len(tree.nodes), 8)
	lv, _ := tree.nodes[1].(types.NodeVbox)
	testing.expect_value(t, lv.aspect, "md/list")
	li, _ := tree.nodes[2].(types.NodeHbox)
	testing.expect_value(t, li.aspect, "md/list-item")
	mk, _ := tree.nodes[3].(types.NodeText)
	testing.expect_value(t, mk.aspect, "md/list-marker")
	testing.expect_value(t, mk.content, "•")
	cn, _ := tree.nodes[4].(types.NodeText)
	testing.expect_value(t, cn.aspect, "md/body")
}

@(test)
test_lower_wrapper_attrs_pass_through :: proc(t: ^testing.T) {
	blocks := parse("hello", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{
		aspect = "card",
		id     = "reply",
	}, context.temp_allocator)
	wv, _ := tree.nodes[0].(types.NodeVbox)
	testing.expect_value(t, wv.aspect, "card")
	testing.expect_value(t, tree.ids[0], "reply")
}

@(test)
test_lower_inline_spans_round_trip :: proc(t: ^testing.T) {
	blocks := parse("hi **there**", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)
	tn, _ := tree.nodes[1].(types.NodeText)
	testing.expect_value(t, len(tn.inline_spans), 2)
	testing.expect_value(t, tn.inline_spans[0].style, text_pkg.Span_Style.Regular)
	testing.expect_value(t, tn.inline_spans[1].style, text_pkg.Span_Style.Bold)
	testing.expect_value(t, tn.inline_spans[1].text, "there")
}
```

- [ ] **Step 2: Run tests to confirm failure.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: compilation fails — `LoweredTree`, `Wrapper_Attrs`, `lower` don't exist.

- [ ] **Step 3: Create `src/redin/markdown/lower.odin`** implementing the lowering.

```odin
package markdown

import "../types"

// Attributes the user wrote on `[:markdown {...} "source"]`.
// Read by the bridge from the Lua table, passed through to lower().
// Empty / zero-value fields mean "not set".
Wrapper_Attrs :: struct {
	aspect:   string,
	id:       string,
	width:    union {types.SizeValue, f32},
	height:   union {types.SizeValue, f32},
	overflow: string,
}

// Synthetic-tree representation of one [:markdown] subtree. Parallel
// arrays in DFS order, mirroring the bridge's flat-array convention so
// flatten_subtree's job is a straight copy with parent-index rebasing.
LoweredTree :: struct {
	nodes:          []types.Node,
	parent_indices: []i32,    // -1 for the root, otherwise 0-based local index
	ids:            []string, // empty string when no :id was set
}

// Lower a parsed []Block plus the user's wrapper attrs into a synthetic
// tree. Always wraps in a vbox even for a single block — predictable
// shape, no aspect collision between user :aspect and inner :md/*.
//
// Allocations come from `allocator` (typically context.temp_allocator).
lower :: proc(blocks: []Block, attrs: Wrapper_Attrs, allocator := context.allocator) -> LoweredTree {
	context.allocator = allocator

	nodes:    [dynamic]types.Node
	parents:  [dynamic]i32
	ids:      [dynamic]string

	// Root wrapper vbox.
	wrapper := types.NodeVbox{
		aspect:   attrs.aspect,
		width:    attrs.width,
		height:   attrs.height,
		overflow: attrs.overflow,
	}
	append(&nodes, wrapper)
	append(&parents, i32(-1))
	append(&ids, attrs.id)

	for blk in blocks {
		emit_block(&nodes, &parents, &ids, blk, 0)
	}

	return LoweredTree{
		nodes          = nodes[:],
		parent_indices = parents[:],
		ids            = ids[:],
	}
}

emit_block :: proc(
	nodes:   ^[dynamic]types.Node,
	parents: ^[dynamic]i32,
	ids:     ^[dynamic]string,
	blk:     Block,
	parent:  i32,
) {
	switch blk.kind {
	case .Paragraph:
		emit_text(nodes, parents, ids, "md/body", "", blk.spans, parent)
	case .Heading_1: emit_text(nodes, parents, ids, "md/h1", "", blk.spans, parent)
	case .Heading_2: emit_text(nodes, parents, ids, "md/h2", "", blk.spans, parent)
	case .Heading_3: emit_text(nodes, parents, ids, "md/h3", "", blk.spans, parent)
	case .Heading_4: emit_text(nodes, parents, ids, "md/h4", "", blk.spans, parent)
	case .Heading_5: emit_text(nodes, parents, ids, "md/h5", "", blk.spans, parent)
	case .Heading_6: emit_text(nodes, parents, ids, "md/h6", "", blk.spans, parent)
	case .List_Group:
		list_idx := i32(len(nodes^))
		append(nodes, types.NodeVbox{aspect = "md/list"})
		append(parents, parent)
		append(ids, "")
		for item in blk.items {
			emit_list_item(nodes, parents, ids, item, list_idx)
		}
	case .List_Item:
		// List items are emitted via emit_list_item from List_Group;
		// reaching here means malformed input — emit as paragraph
		// fallback so we don't lose content.
		emit_text(nodes, parents, ids, "md/body", "", blk.spans, parent)
	}
}

emit_list_item :: proc(
	nodes:   ^[dynamic]types.Node,
	parents: ^[dynamic]i32,
	ids:     ^[dynamic]string,
	item:    Block,
	parent:  i32,
) {
	hbox_idx := i32(len(nodes^))
	append(nodes, types.NodeHbox{aspect = "md/list-item"})
	append(parents, parent)
	append(ids, "")

	marker_text := item.marker
	if len(marker_text) == 0 do marker_text = "•"
	emit_text(nodes, parents, ids, "md/list-marker", marker_text, nil, hbox_idx)
	emit_text(nodes, parents, ids, "md/body", "", item.spans, hbox_idx)
}

emit_text :: proc(
	nodes:   ^[dynamic]types.Node,
	parents: ^[dynamic]i32,
	ids:     ^[dynamic]string,
	aspect:  string,
	plain:   string,
	spans:   []Span,
	parent:  i32,
) {
	t := types.NodeText{
		aspect       = aspect,
		content      = plain,
		inline_spans = spans,
	}
	// If spans are provided, content stays empty — the renderer reads
	// from inline_spans. If spans is nil and plain is set (markers),
	// content drives a plain render.
	append(nodes, t)
	append(parents, parent)
	append(ids, "")
}
```

- [ ] **Step 4: Run tests to confirm pass.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: all lowering tests pass alongside parser tests.

- [ ] **Step 5: Build full binary.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success.

- [ ] **Step 6: Commit.**

```bash
git add src/redin/markdown/lower.odin src/redin/markdown/lower_test.odin
git commit -m "$(cat <<'EOF'
feat(markdown): LoweredTree + markdown.lower

lower() takes parsed []Block + wrapper attrs and produces a
synthetic node subtree (parallel arrays of Node + parent-index +
id, in DFS order) ready for the bridge to flatten into its
flat-array representation. Always wraps in a vbox; the user's
wrapper attrs land on that vbox; inner aspects come from :md/*.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `bridge.flatten_subtree` + `:markdown` keyword dispatch

**Why:** Wire the new pipeline. Bridge dispatches on tag, runs parse + lower + flatten_subtree for `:markdown`, leaves all other tags on the existing path.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Locate the dispatch site** in `lua_flatten_node`.

Run:
```bash
grep -n "lua_read_node\|tag :=" src/redin/bridge/bridge.odin | head
```

Find the line that reads the tag (around line 1100-1120) and the call to `lua_read_node` (around line 1146). The markdown branch goes between "tag has been read" and "lua_read_node is called".

- [ ] **Step 2: Add `flatten_subtree` proc** in `bridge.odin`.

Place near `lua_flatten_node`. Two-pass walk: emit all nodes (DFS order is already the local order from `lower`), then rewrite parent indices and accumulate child buckets.

```odin
flatten_subtree :: proc(b: ^Bridge, tree: markdown.LoweredTree, parent_flat_idx: i32, cur: ^[dynamic]u8) {
	local_to_flat := make([]i32, len(tree.nodes), context.temp_allocator)

	// Pass 1: append nodes. DFS order is the local order from lower().
	for node, i in tree.nodes {
		local_to_flat[i] = i32(len(b.nodes))
		append(&b.nodes, node)
		append(&b.node_animations, nil)
		path_copy := make([]u8, len(cur^))
		copy(path_copy, cur^[:])
		append(&b.paths, path_copy)
		// Reserve slots — Pass 2 fills them.
		append(&b.parent_indices, i32(0))
		append(&b.children_list, types.Children{})
	}

	// Pass 2: rewrite parent_indices and accumulate per-parent child lists.
	per_local: [dynamic][dynamic]i32
	resize(&per_local, len(tree.nodes))
	defer {
		for &c in per_local do delete(c)
		delete(per_local)
	}

	for i, _ in tree.nodes {
		flat_idx := local_to_flat[i]
		local_parent := tree.parent_indices[i]
		if local_parent < 0 {
			b.parent_indices[flat_idx] = parent_flat_idx
		} else {
			b.parent_indices[flat_idx] = local_to_flat[local_parent]
			append(&per_local[local_parent], flat_idx)
		}
	}

	for i, _ in tree.nodes {
		bucket := per_local[i][:]
		if len(bucket) == 0 do continue
		flat_idx := local_to_flat[i]
		cv := make([]i32, len(bucket))
		copy(cv, bucket)
		b.children_list[flat_idx] = types.Children{value = cv, length = i32(len(bucket))}
	}
}
```

**ID storage caveat:** the bridge's existing approach to `:id` may not be a parallel `b.ids` slice — it could be an attrs-on-node lookup or a separate map. Before this task, grep for how `:id` is stored elsewhere:

```bash
grep -n '"id"\|attrs\[\\"id\\"\]\|node_id' src/redin/bridge/bridge.odin | head
```

Then thread `tree.ids[i]` into whatever that storage is for the wrapper node only (i == 0). If id storage is per-attrs (e.g. via the same map the dev-server traversal uses), copy `tree.ids[0]` into the wrapper node's attrs there. If id storage doesn't exist as a unified concept yet, mark this as a known gap and add a note in the task's commit message. Tests in `test_markdown.bb` use `(find-element {:id :md})` — that helper's traversal logic determines what storage we need to populate.

- [ ] **Step 3: Refactor `lua_flatten_node` to dispatch on tag before reserving slots.**

The current shape (around lines 1109-1126) reserves path/parent_indices/children_list slots at `my_idx` *before* reading the tag. For markdown that's a problem because `flatten_subtree` does its own slot appends — running both paths would double-push at `my_idx`. The fix: read the tag first, branch to markdown if applicable, otherwise run the existing flow.

Find:

```odin
lua_flatten_node :: proc(L: ^Lua_State, index: i32, cur: ^[dynamic]u8, b: ^Bridge, parent_idx: int) {
	abs_idx := index < 0 ? lua_gettop(L) + index + 1 : index
	my_idx := len(b.nodes)

	// Store path
	p := make([]u8, len(cur))
	copy(p, cur[:])
	append(&b.paths, types.Path{value = p, length = u8(len(p))})
	append(&b.parent_indices, parent_idx)
	append(&b.children_list, types.Children{})

	// Position 1: tag (keyword string)
	lua_rawgeti(L, abs_idx, 1)
	tag: string
	if lua_isstring(L, -1) {
		tag = string(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)
```

Replace with:

```odin
lua_flatten_node :: proc(L: ^Lua_State, index: i32, cur: ^[dynamic]u8, b: ^Bridge, parent_idx: int) {
	abs_idx := index < 0 ? lua_gettop(L) + index + 1 : index

	// Position 1: tag (keyword string) — read first so we can dispatch.
	lua_rawgeti(L, abs_idx, 1)
	tag: string
	if lua_isstring(L, -1) {
		tag = string(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	// Markdown branch: parse + lower + flatten_subtree handles all
	// slot management itself, so we early-return before the normal
	// path's slot reservation runs.
	if tag == "markdown" {
		// Position 2 — wrapper attrs (optional).
		attrs_idx: i32 = 0
		lua_rawgeti(L, abs_idx, 2)
		if lua_istable(L, -1) {
			attrs_idx = lua_gettop(L)
		} else {
			lua_pop(L, 1)
		}

		// Position 3 — source string.
		source: string
		lua_rawgeti(L, abs_idx, 3)
		if lua_isstring(L, -1) {
			source = string(lua_tostring_raw(L, -1))
		}
		lua_pop(L, 1)

		attrs: markdown.Wrapper_Attrs
		if attrs_idx > 0 {
			attrs.aspect   = lua_get_string_field(L, attrs_idx, "aspect")
			attrs.id       = lua_get_string_field(L, attrs_idx, "id")
			attrs.width    = lua_get_size_f32(L, attrs_idx, "width")
			attrs.height   = lua_get_size_f32(L, attrs_idx, "height")
			attrs.overflow = lua_get_string_field(L, attrs_idx, "overflow")
			lua_pop(L, 1)
		}

		blocks := markdown.parse(source, context.temp_allocator)
		tree := markdown.lower(blocks, attrs, context.temp_allocator)
		flatten_subtree(b, tree, i32(parent_idx), cur)
		return
	}

	// Non-markdown path: reserve our slot at my_idx before doing
	// anything else, just as before.
	my_idx := len(b.nodes)
	p := make([]u8, len(cur))
	copy(p, cur[:])
	append(&b.paths, types.Path{value = p, length = u8(len(p))})
	append(&b.parent_indices, parent_idx)
	append(&b.children_list, types.Children{})
```

(The rest of the function continues unchanged — it already had `tag` available, and that variable is still in scope in this restructure.)

Note that `flatten_subtree`'s signature uses `i32` for `parent_flat_idx` while `lua_flatten_node` takes `parent_idx: int` — convert at the call site as shown.

Add the import alongside other bridge package imports:

```odin
import "../markdown"
```

Also revisit the `flatten_subtree` impl to match the bridge's actual `b.paths` type — the existing code wraps each path in `types.Path{value = p, length = u8(len(p))}`, not a raw `[]u8`. Update Pass 1 in flatten_subtree from:

```odin
		path_copy := make([]u8, len(cur^))
		copy(path_copy, cur^[:])
		append(&b.paths, path_copy)
```

to:

```odin
		path_copy := make([]u8, len(cur^))
		copy(path_copy, cur^[:])
		append(&b.paths, types.Path{value = path_copy, length = u8(len(path_copy))})
```

- [ ] **Step 4: Build to confirm wiring compiles.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success.

- [ ] **Step 5: Smoke-test by running** the existing markdown app — it still uses `:text {:markdown true}` (old path) so this confirms nothing regressed.

Run (in one terminal):
```bash
./build/redin --dev test/ui/markdown_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/frames | head -c 200
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
wait
```

Expected: dev server starts, returns a frame, shuts down cleanly.

- [ ] **Step 6: Commit.**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): :markdown keyword dispatch + flatten_subtree

lua_flatten_node dispatches on tag == "markdown": reads source +
wrapper attrs, runs markdown.parse + markdown.lower, and calls the
new flatten_subtree to project the LoweredTree into the bridge's
flat arrays. Non-markdown tags are unchanged.

flatten_subtree mirrors the Lua-table flattening conventions
(DFS, parent_indices, children_list, node_animations alignment)
so downstream packages can't tell synthetic nodes apart from
user-authored ones.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Render branch on `inline_spans`

**Why:** Synthetic text nodes from markdown lowering carry inline spans. The renderer must use the new span-aware path for them, and keep the old plain path for ordinary text nodes.

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Locate `draw_text`.**

Run:
```bash
grep -n "draw_text\|n.markdown" src/redin/render.odin | head
```

Find the existing `if n.markdown { … return }` block (around line 1350).

- [ ] **Step 2: Replace that block** with an `inline_spans` branch.

Find:

```odin
	if n.markdown {
		blocks := markdown.parse(n.content, context.temp_allocator)
		laid := markdown.layout(blocks, font_name, font_size, lh_ratio, rect.width, context.temp_allocator)
		markdown.draw(laid, rect, text_color, font_size, font_name, lh_ratio)
		return
	}
```

Replace with:

```odin
	if len(n.inline_spans) > 0 {
		// Resolve :md/code styling once if it's set; otherwise zero
		// values trigger the function's defaults.
		code_style: text_pkg.Span_Code_Style
		if t, ok := theme["md/code"]; ok {
			if len(t.font) > 0 do code_style.font_name = t.font
			if t.bg != {} do code_style.bg = t.bg
			if t.color != {} {
				code_style.color = t.color
				code_style.color_set = true
			}
		}
		text_pkg.span_layout_and_draw(
			n.inline_spans,
			rect,
			font_name,
			font_size,
			lh_ratio,
			text_color,
			code_style,
		)
		return
	}
	if n.markdown {
		// Legacy path — kept until Task 13 removes the bool.
		blocks := markdown.parse(n.content, context.temp_allocator)
		laid := markdown.layout(blocks, font_name, font_size, lh_ratio, rect.width, context.temp_allocator)
		markdown.draw(laid, rect, text_color, font_size, font_name, lh_ratio)
		return
	}
```

Confirm the imports include both `text_pkg "text"` (already present) and `markdown` (already present). If `text_pkg` isn't aliased, alias it now.

- [ ] **Step 3: Build.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success.

- [ ] **Step 4: Smoke test** by launching the existing markdown app (still on `:text {:markdown true}`) — confirms the legacy fallback still works.

Run:
```bash
./build/redin --dev test/ui/markdown_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
wait
```

Expected: clean run.

- [ ] **Step 5: Commit.**

```bash
git add src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(render): branch on NodeText.inline_spans

draw_text now uses text.span_layout_and_draw when inline_spans is
set, falling through to the existing markdown-bool legacy path
otherwise. The legacy path is retained for one more task so the
:markdown keyword dispatch can be exercised end-to-end before old
code is removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Migrate `markdown_app.fnl` + `test_markdown.bb` to `[:markdown]`

**Why:** First end-to-end exercise of the new pipeline. Once this task is green, the legacy `:text {:markdown true}` path can be deleted.

**Files:**
- Modify: `test/ui/markdown_app.fnl`
- Modify: `test/ui/test_markdown.bb`

- [ ] **Step 1: Rewrite `test/ui/markdown_app.fnl`** to use the new element with heading + list.

```fennel
(local dataflow (require :dataflow))
(local theme    (require :theme))

(theme.set-theme
  {:surface {:bg [30 33 42] :padding [16 16 16 16]}
   :card    {:bg [40 44 52] :padding [16 16 16 16]}})

(dataflow.init {})

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:markdown {:id :md :aspect :card :width :full}
      "# Title

A paragraph with **bold** and _italic_ and `code` inline.

Second paragraph after a blank line.
Soft break here
on the next line.

- first item
- second item
- third item"]])
```

- [ ] **Step 2: Rewrite `test/ui/test_markdown.bb`** to assert the lowered tree shape.

The framework (`test/ui/redin_test.bb`) represents frames as positional vectors `[tag attrs & children]` and exposes `find-element` / `find-elements` with `:tag` / `:id` / `:aspect` criteria (aspect criteria can be a string or keyword; the matcher compares via `name`). Use those directly:

```clojure
(require '[redin-test :refer :all]
         '[clojure.java.io :as io])

(defn- ensure-artifacts-dir []
  (let [d (io/file "test/ui/artifacts")]
    (when-not (.exists d) (.mkdirs d))))

(deftest markdown-wrapper-is-a-vbox
  (let [n (find-element {:id :md})]
    (assert n "markdown wrapper must exist at :id :md")
    (assert (= "vbox" (first n))
            (str "wrapper must be a vbox; got " (pr-str (first n))))))

(deftest markdown-heading-rendered
  (let [hits (find-elements {:tag :text :aspect "md/h1"})]
    (assert (seq hits)
            "expected at least one :md/h1 text node in the lowered tree")))

(deftest markdown-paragraph-rendered
  (let [hits (find-elements {:tag :text :aspect "md/body"})]
    ;; Paragraphs + list-item content both use :md/body, so >= 2.
    (assert (>= (count hits) 2)
            (str "expected multiple :md/body text nodes; got " (count hits)))))

(deftest markdown-list-markers-rendered
  (let [hits (find-elements {:tag :text :aspect "md/list-marker"})]
    (assert (= 3 (count hits))
            (str "expected 3 list markers (one per item); got " (count hits)))))

(deftest markdown-renders-without-error
  (ensure-artifacts-dir)
  (wait-ms 100)
  (screenshot "test/ui/artifacts/markdown_render.png"))
```

- [ ] **Step 3: Run the test.**

Run:
```bash
./build/redin --dev test/ui/markdown_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_markdown.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
wait
```

Expected: tests pass; screenshot at `test/ui/artifacts/markdown_render.png` shows the heading + paragraphs + list rendering.

- [ ] **Step 4: Eyeball the screenshot.** Open it; confirm heading is bigger than body, list items have visible markers, inline emphasis renders in bold/italic/mono.

- [ ] **Step 5: Run the full UI suite** to confirm no other test regressed.

Run:
```bash
bash test/ui/run-all.sh --headless
```

Expected: all tests pass.

- [ ] **Step 6: Commit.**

```bash
git add test/ui/markdown_app.fnl test/ui/test_markdown.bb
git commit -m "$(cat <<'EOF'
test(ui): migrate markdown_app to [:markdown] element

Exercises the full new pipeline: parser (heading + list), lower,
flatten_subtree, span-aware render. Tests assert the lowered tree
exposes :md/h1, :md/body, and :md/list-marker aspects.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Remove `:text {:markdown true}` from the bridge

**Why:** With the markdown app migrated, the legacy attribute can go. One less surface area to maintain.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Locate the legacy attr read.**

Run:
```bash
grep -n 'lua_get_bool_field_opt(L, attrs_idx, "markdown")' src/redin/bridge/bridge.odin
```

Expected: one hit, around line 1371, inside the `case "text":` of `lua_read_node`.

- [ ] **Step 2: Delete those lines.**

Find:

```odin
			if md, exists := lua_get_bool_field_opt(L, attrs_idx, "markdown"); exists {
				t.markdown = md
			}
```

Delete them entirely.

- [ ] **Step 3: Build.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success — the `t.markdown` field still exists, just nobody writes it.

- [ ] **Step 4: Run the UI suite** to confirm no test relied on the legacy attribute.

Run:
```bash
bash test/ui/run-all.sh --headless
```

Expected: all pass.

- [ ] **Step 5: Commit.**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
refactor(bridge): drop :text {:markdown true} attr

[:markdown] is the user-facing surface; the legacy attribute is no
longer read. NodeText.markdown bool field is removed in the next
commit alongside the legacy render branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Remove `NodeText.markdown` bool + delete the old markdown render code

**Why:** Cleanup. The legacy render branch and the old `markdown.layout` / `markdown.draw` / `markdown.Span_Box` / `markdown.Laid_Block` are now dead.

**Files:**
- Modify: `src/redin/types/view_tree.odin`
- Modify: `src/redin/render.odin`
- Delete: `src/redin/markdown/render.odin`

- [ ] **Step 1: Remove the field** from `types/view_tree.odin`.

Find:

```odin
	markdown:       bool,
	inline_spans:   []text.Span,
```

Delete the `markdown` line. Keep `inline_spans`.

- [ ] **Step 2: Remove the legacy render branch** in `src/redin/render.odin`.

Find the block added in Task 10:

```odin
	if n.markdown {
		// Legacy path — kept until Task 13 removes the bool.
		blocks := markdown.parse(n.content, context.temp_allocator)
		laid := markdown.layout(blocks, font_name, font_size, lh_ratio, rect.width, context.temp_allocator)
		markdown.draw(laid, rect, text_color, font_size, font_name, lh_ratio)
		return
	}
```

Delete it.

- [ ] **Step 3: Delete `src/redin/markdown/render.odin`.**

Run:
```bash
git rm src/redin/markdown/render.odin
```

Expected: file removed; `markdown` package now contains parser, lower, and tests only.

- [ ] **Step 4: Update the `markdown` import in `render.odin`** if it now becomes unused (the `markdown.parse` / `markdown.layout` / `markdown.draw` calls are gone; `markdown` is no longer needed in this file).

Find:

```odin
import "markdown"
```

Delete if no other reference exists. (`grep -n markdown\\. src/redin/render.odin` after the delete should show no hits.)

- [ ] **Step 5: Build.**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: success.

- [ ] **Step 6: Run the full Odin test suite.**

Run:
```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/text     -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: all pass.

- [ ] **Step 7: Run the Fennel suite.**

Run:
```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: all pass.

- [ ] **Step 8: Run the UI suite.**

Run:
```bash
bash test/ui/run-all.sh --headless
```

Expected: all pass.

- [ ] **Step 9: Memory smoke** — confirm the new pipeline doesn't leak.

Run:
```bash
./build/redin --dev --track-mem test/ui/markdown_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
wait
```

Expected: no `leak` or `outstanding` allocations reported on stderr beyond what `main` reports for the same app shape.

- [ ] **Step 10: Commit.**

```bash
git add src/redin/types/view_tree.odin src/redin/render.odin src/redin/markdown/render.odin
git commit -m "$(cat <<'EOF'
refactor(markdown): drop NodeText.markdown bool + legacy render

The :markdown keyword dispatch in the bridge is the only path now;
the old span-aware render lifted to text.span_layout_and_draw in
Task 2. Deletes src/redin/markdown/render.odin.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Documentation

**Why:** Public docs and the in-tree skills are part of the user contract. They must reflect the new surface.

**Files:**
- Modify: `docs/core-api.md`
- Modify: `docs/reference/elements.md`
- Modify: `.claude/skills/redin-dev/SKILL.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `docs/core-api.md`.**

Find the `:text` attribute table row for `markdown` (around the line that starts with `| `markdown` | boolean ...`). Delete the row.

Find the `:markdown` attribute description paragraph elsewhere in the doc and replace with a `:markdown` element section. Add it under the "Elements" listing (alongside `:text`, `:input`, etc.):

````markdown
### `:markdown`

Renders a string of inline markdown source as a subtree of regular
nodes. The bridge parses the source into block + inline spans, lowers
to a `:vbox` wrapping per-block `:text` / `:hbox` nodes, and themes
them with the `md/*` aspect family.

```fennel
[:markdown {:aspect :card :id :reply :width :full :overflow :scroll-y}
  "# Title

A paragraph with **bold** and _italic_ and `code` text.

- first
- second"]
```

| Attr | Type | Notes |
|------|------|-------|
| `:aspect` | keyword | Themes the wrapper vbox (padding, bg, border). Ordinary user aspect — no `md/` prefix. |
| `:id` | keyword | Lands on the wrapper. `(find-element {:id ...})` returns it. |
| `:width`, `:height` | size | Sizing of the wrapper. |
| `:overflow` | keyword | Forwarded to the wrapper. `:scroll-y` for tall blocks. |

V1 syntax: paragraphs (blank line), soft breaks (two-space EOL),
inline `**bold**` / `_italic_` / `*italic*` / `` `code` ``,
ATX headings `#`–`######` at column 0, flat unordered lists (`-`,
`*` at column 0) and flat ordered lists (`<digit>+. ` at column 0).
Nested lists, code blocks, links, images, tables, and nested inline
emphasis are not supported in v1.

The styling of `:md/h1` … `:md/h6`, `:md/body`, `:md/list`,
`:md/list-item`, `:md/list-marker`, and `:md/code` aspects ships
with the framework; override individual entries via your normal
`(theme.set-theme {…})` call.
````

Find the agent channel narrative starting around line 669:

```
The framework dispatches `:event/agent-edit {id "reply" content "**Answer:** 4"}`,
the Fennel handler stores it in `db.agent.reply`, and the next render
shows it in the `:reply` text node. Set `:markdown true` on the text node
to have the content rendered as inline markdown (see `:markdown` in the
attribute table above; v1 supported syntax: bold, italic, inline code,
paragraphs, soft breaks). Extended syntax (headings, lists, links, images,
tables, code blocks) is tracked in issue #100.
```

Replace with:

```
The framework dispatches `:event/agent-edit {id "reply" content "**Answer:** 4"}`,
the Fennel handler stores it in `db.agent.reply`, and the next render
shows it in the `:reply` text node. To render the content as markdown
instead of plain text, add a sibling `[:markdown]` element reading the
same value:

[:vbox {}
  ;; Writable target — what the agent writes to.
  [:text {:id :reply :agent :edit
          :content (subscribe :sub/agent-reply)}]
  ;; Formatted preview alongside (read-only).
  [:markdown {:aspect :card} (subscribe :sub/agent-reply)]]

The agent target itself stays a plain `:text` because the agent
channel addresses content by `:id`, and the `[:markdown]` element
lowers to a vbox subtree that doesn't carry the original source string
in a place the channel can read or write. The markdown element is the
read-side preview; the `:text` is the write-side target.

[:markdown] supports: paragraphs (blank line), soft breaks (two-space
EOL), inline `**bold**` / `_italic_` / `` `code` ``, ATX headings
`#`–`######`, and flat ordered/unordered lists. Nested lists, code
blocks, links, images, tables, and nested inline emphasis are not
supported.
```

- [ ] **Step 2: Update `docs/reference/elements.md`.**

Find the row for `markdown` under the `:text` element's attribute table (around line 91). Delete it.

Add a new section for `:markdown` mirroring what was added in core-api.md (concise version — just the attr table and a one-line summary).

- [ ] **Step 3: Update `.claude/skills/redin-dev/SKILL.md`.**

Find the "Node types" line:

```
NodeStack, NodeCanvas, NodeVbox, NodeHbox, NodeInput, NodeButton, NodeText, NodeImage, NodePopout, NodeModal
```

Add `NodeMarkdown` (or whatever the actual type name is — may be that markdown lowers fully and there's no NodeMarkdown; in that case, list `:markdown` as an element keyword, not a node type, in a separate sentence).

Find:

```
NodeText accepts `:markdown` (boolean, default `false`); when `true`, inline markdown is rendered ...
```

Delete that whole paragraph. Replace with one line under the elements list:

```
`:markdown` renders a string of markdown source as a lowered subtree of vbox/hbox/text nodes themed with the `md/*` aspect family. See `docs/core-api.md` for syntax + attribute table.
```

- [ ] **Step 4: Update `CLAUDE.md`.**

Find the "Key conventions / Node types" listing. Add `:markdown` to the elements list. If `:markdown true` on text is mentioned anywhere as a current feature, remove it.

- [ ] **Step 5: Sweep for stale references.**

Run:
```bash
rg -n ':text \{:markdown true\}|n\.markdown|markdown true' docs/ .claude/skills/ CLAUDE.md
```

Expected: zero hits. If any remain, update them.

- [ ] **Step 6: Commit.**

```bash
git add docs/core-api.md docs/reference/elements.md .claude/skills/redin-dev/SKILL.md CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: [:markdown] element + md/* aspect family

Replaces the old :text {:markdown true} attribute with a first-class
[:markdown] element section in core-api.md and elements.md. Updates
the agent-channel example to show :reply as the writable text node
and a sibling [:markdown] as the formatted preview. Skill files and
CLAUDE.md updated for the new surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] **All tests green.**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/text     -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
luajit test/lua/runner.lua test/lua/test_*.fnl
bash test/ui/run-all.sh --headless
```

- [ ] **Memory clean** under `--track-mem` for the markdown app.

- [ ] **Visual sanity check** — open `test/ui/artifacts/markdown_render.png` and confirm headings, paragraphs, and lists all render correctly.

- [ ] **Stale-reference sweep:**

```bash
rg -n ':markdown true|n\.markdown|markdown\.parse\b|markdown\.layout|markdown\.draw' src/ docs/ .claude/skills/ CLAUDE.md test/
```

Expected hits only inside the markdown package itself (`markdown.parse` is still called from the bridge).

- [ ] **Branch ready for PR.**
