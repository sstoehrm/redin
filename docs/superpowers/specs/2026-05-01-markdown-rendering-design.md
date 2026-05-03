# Markdown rendering for `:text` nodes

**Status:** design
**Date:** 2026-05-01
**Issue:** #100

## Problem

The agent channel feature (PR #101, merged) lets an external agent post
text content into `:text {:agent :edit}` nodes. The natural use case
is the agent writing a structured reply — but plain-text rendering
loses every cue (emphasis, code, paragraph breaks) the agent might
have authored.

## Goals

- A new boolean attribute `:text {:markdown true}` enables markdown
  rendering for that node.
- Inline emphasis: `**bold**`, `_italic_` / `*italic*`, `` `code` ``.
- Block structure: paragraph breaks (blank line), soft line breaks
  (two-space EOL).
- Plain `:text` (no `:markdown true`) is unchanged — same code path,
  same output, same performance.
- Themes still control the parent aspect's font/size/color; markdown
  styles inherit.

## Non-goals (deferred to a follow-up issue)

- Headings (`#`, `##`, …)
- Lists (`-`, `1.`)
- Links (`[text](url)`)
- Images (`![alt](url)`)
- Tables
- Triple-backtick code blocks
- Nested styles (`**bold _italic_**` — outer wins, inner is literal)
- Per-style theme overrides (`:body {:bold {…} :italic {…}}`)
- Streaming agent writes
- CJK / non-ASCII word breaking

## Design overview

Three layers in a new package `src/redin/markdown/`:

1. **Parser** — single-pass tokenizer that produces a list of `Block`s,
   each containing a list of `Span`s (text + style enum).
2. **Layout** — span-aware word-wrap that places each span on a line,
   respecting per-style font metrics. Greedy, one-pass.
3. **Render** — iterates laid-out span boxes and calls `rl.DrawTextEx`
   per span, with a small bg fill for code spans.

Plus:
- One new field `markdown: bool` on `types.NodeText`.
- Bridge parses `:markdown true` attr in `lua_read_node`.
- `render.draw_text` branches: if `n.markdown`, dispatches to the
  markdown render path; otherwise unchanged.
- Two new italic fonts embedded: Inter Italic, Noto Serif Italic.
  Mono italic falls back to mono regular.

### Parser

```odin
package markdown

Span_Style :: enum u8 { Regular, Bold, Italic, Code }

Span :: struct {
    style: Span_Style,
    text:  string,         // slice of original input
}

Block_Kind :: enum u8 { Paragraph }

Block :: struct {
    kind:  Block_Kind,
    spans: []Span,
}

parse :: proc(src: string, allocator := context.allocator) -> []Block
```

Tokenization rules:
- `**...**` → Bold span; greedy from first `**` to next `**`.
- `_..._` and `*...*` → Italic span. Closer must match opener.
- `` `...` `` → Code span. Backtick is literal; can't span paragraphs.
- Two-space-EOL → soft break (`\n` retained in span text).
- Blank line → paragraph break (new `Block`).
- Unmatched delimiter → emitted as literal text. No errors.
- **No nesting** — first opening delimiter wins until its closer; any
  inner delimiters are literal.

`Block_Kind` is an enum to leave room for Heading/List/CodeBlock
variants in the follow-up issue without an API break.

### Layout

```odin
Span_Box :: struct {
    style:  Span_Style,
    text:   string,        // slice
    x:      f32,
    y:      f32,           // top-of-line, block-relative
    width:  f32,
    height: f32,
}

Laid_Block :: struct {
    spans:        []Span_Box,
    total_height: f32,
}

layout :: proc(blocks: []Block,
               base_font_name: string,
               base_font_size: f32,
               line_height_ratio: f32,
               max_width: f32) -> []Laid_Block
```

Algorithm:
1. For each block, split spans into "wrap units" — whitespace-separated
   tokens, plus literal `\n` as a forced break.
2. Measure each unit with its style's font:
   - Regular → `font.get(base_font_name, .Regular)`
   - Bold → `font.get(base_font_name, .Bold)`
   - Italic → `font.get(base_font_name, .Italic)` (falls back to Regular
     when no italic font is loaded)
   - Code → `font.get("mono", .Regular)` (always)
3. Greedy line-fill: pack units onto current line until next unit would
   exceed `max_width`; flush, start new line.
4. Each unit becomes one `Span_Box` with x/y/width/height set.
5. After the last block, return total stacked height (sum of block
   heights + paragraph gaps of one `lh`).

Token boundaries split on ASCII whitespace. Mid-token style transitions
(e.g., `pre**fix**`) split the word into adjacent units that wrap
together unless one would overflow.

### Render

```odin
draw :: proc(laid: []Laid_Block, rect: rl.Rectangle, color: rl.Color)
```

Iterates `Span_Box`es and calls `rl.DrawTextEx` per span, using the
style→font mapping above. Code spans get a subtle bg fill
(`rl.Color{60, 60, 70, 255}` — hardcoded for v1; theme override is
deferred).

All spans use the parent aspect's `color`. Italic spans render in the
loaded italic font (if available) or fall back to regular.

### Wiring

`src/redin/types/view_tree.odin` adds `markdown: bool` to `NodeText`.

`src/redin/bridge/bridge.odin` reads `:markdown` boolean attr in
`lua_read_node` for the `text` case.

`src/redin/render.odin draw_text` becomes:

```odin
draw_text :: proc(idx: int, rect: rl.Rectangle, n: types.NodeText,
                  theme: map[string]types.Theme) {
    if len(n.content) == 0 do return
    // ...resolve font_size, text_color, font_name, font_weight, lh_ratio
    //    from theme[n.aspect]...

    if n.markdown {
        blocks := markdown.parse(n.content, context.temp_allocator)
        max_width: f32 = rect.width
        laid := markdown.layout(blocks, font_name, font_size, lh_ratio, max_width)
        markdown.draw(laid, rect, text_color)
        return
    }

    // ...existing path: compute_lines + draw_lines...
}
```

Markdown uses `context.temp_allocator` so per-frame allocations are
freed automatically. No per-idx cache for markdown in v1 — reparse +
relayout each frame. If profiling shows a hot path, a follow-up adds
caching (same shape as `text_pkg.lookup_lines`).

### Embedded italic fonts

Add to `src/redin/font/embedded.odin`:

```odin
inter_italic       := #load("Inter-Italic.ttf")
noto_serif_italic  := #load("NotoSerif-Italic.ttf")
```

```odin
load_font("sans",  .Italic, inter_italic)
load_font("serif", .Italic, noto_serif_italic)
```

Mono italic is not embedded; `font.get("mono", .Italic)` falls back to
`mono Regular` per the existing fallback logic.

Binary growth: ~150KB (Inter Italic) + ~110KB (Noto Serif Italic) = ~260KB.

## Examples

`test/ui/markdown_app.fnl`:

```fennel
(local theme (require :theme))

(theme.set-theme
  {:surface {:bg [30 33 42] :padding [16 16 16 16]}
   :body    {:font-size 16 :color [240 240 240] :line-height 1.5}})

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:text {:id :md :markdown true :aspect :body}
           "**Bold** and _italic_ and `code` inline.

Second paragraph after a blank line.
Soft break here  
on the next line."]])
```

## Testing

### Odin unit tests — `src/redin/markdown/parser_test.odin`

- `test_plain_text` — no markup, one block, one Regular span.
- `test_bold` — `**hi**` → one Bold span.
- `test_italic_star` and `test_italic_underscore` — both produce Italic.
- `test_code` — backticks → Code span.
- `test_paragraphs` — blank line splits into two blocks.
- `test_soft_break` — two-space-EOL produces `\n` inside the span.
- `test_unmatched_delimiter` — `"**bold without close"` renders literally.
- `test_no_nesting_v1` — `"**outer _inner_**"` → one Bold span containing
  literal `_inner_`.
- `test_mixed` — all features combined in one input.

### UI test — `test/ui/test_markdown.bb`

- Boot `markdown_app.fnl`.
- Fetch `/frames`; assert `:markdown true` in attrs of the text node.
- Take a `screenshot test/ui/artifacts/markdown_render.png`.
- No pixel assertions — artifact for human/agent inspection.

## Documentation updates

- `docs/core-api.md` — add `:markdown` to the `:text` attribute table;
  small section on supported syntax.
- `docs/reference/elements.md` — `:markdown` row in text attrs.
- `.claude/skills/redin-dev/SKILL.md` — note the attribute and v1 syntax.
- `CLAUDE.md` — no change (not a top-level convention).

## Failure modes

- **Italic font unavailable** (e.g. someone overrides `sans` to a
  family without italic): `font.get` falls back to Regular. Italic
  spans visually merge with regular — known limitation, documented.
- **Backtick at end of input without closer**: span emitted as literal
  backtick + content.
- **Markdown content longer than 16KB**: parser is single-pass O(n);
  fine. Layout is also O(units). No fixed limits.
- **Mid-word style transition** (`pre**bold**suf`): three adjacent
  wrap units. They render as one visual word as long as they fit on
  the line. If forced to wrap, the break happens at the unit boundary
  (which is also the style boundary). Acceptable for v1.

## Out of scope (follow-up issue to be filed)

The follow-up issue captures every deferral above (headings, lists,
links, images, tables, code blocks, nested styles, theme overrides,
streaming, CJK breaking, per-idx layout cache).
