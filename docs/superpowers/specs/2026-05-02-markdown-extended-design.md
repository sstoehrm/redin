# Markdown rendering — extended syntax + features (tier 1)

## Goal

Extend the v1 markdown renderer (#100) with the most-used features still missing:
headings, nested inline styles, and per-style theme overrides. Tracker: #105.
Larger items (lists, code blocks, links, images, tables, layout cache, CJK
breaking, streaming) remain deferred under #102.

The renderer stays opt-in via the existing `:markdown` attribute on `:text`
nodes. No behavior change for nodes without `:markdown true`.

## Public surface

### 1. Headings

```fennel
[:text {:markdown true :aspect :body}
  "# h1 title

   ## h2 with **bold** inline

   normal paragraph"]
```

A paragraph that begins with 1–6 `#` followed by a space becomes a heading
block. CommonMark behavior:

- `#` count clamped to 6.
- Trailing `#`s on the line are stripped.
- Surrounding whitespace trimmed.
- Heading content is parsed as inline (so `# **bold** title` works).

Theme: a heading at level N looks up `:h<N>` (e.g. `:h1`) on the host's theme
map. If present, **non-zero** fields (`font_size`, `color`, `weight`,
`line_height`) override the host aspect; zero fields inherit from the host.
This matches the existing convention: zero is "absent". If `:h<N>` is not in
the theme map at all, the heading renders at the host aspect's font_size
scaled by:

| Level | Scale |
|-------|-------|
| 1     | 2.0×  |
| 2     | 1.7×  |
| 3     | 1.4×  |
| 4     | 1.2×  |
| 5     | 1.1×  |
| 6     | 1.0×  |

Heading weight defaults to bold; the theme aspect can override.

### 2. Nested inline styles

`**bold _italic_**` renders the inner span as bold-italic. Symmetric for
`_italic **bold**_`. Backtick code stays a leaf (no recursion inside).

`Span_Style` gets a `Bold_Italic` variant and `Font_Style` matches. We
deliberately do **not** add new .ttf assets in this PR; embedding
`Inter-BoldItalic` and `NotoSerif-BoldItalic` is a trivial follow-up if visual
quality demands it.

`font.get`'s current fallback chain only steps `non-Regular → Regular`. To
honor option B, extend the chain so `Bold_Italic` falls back to `Bold` *before*
falling further back to `Regular`. Concretely, in `font.get`: if requested
`Bold_Italic` is missing, try `Bold` next; if that's also missing, the existing
`Italic → Regular` step takes over. One added arm in the existing chain.

Parser becomes recursive: when an emphasis delimiter is matched and a span is
emitted, the body is re-tokenised so inner emphasis / code is recognized.
Unbalanced delimiters keep the existing literal-fallback behavior.

### 3. Per-style theme overrides

Theme entries grow optional `:bold` / `:italic` / `:code` sub-tables that
override `color` (and `bg` for `:code`) on top of the host aspect:

```fennel
(theme-mod.set-theme
  {:body {:font-size 14 :color [216 222 233]
          :bold   {:color [255 255 255]}
          :italic {:color [180 180 220]}
          :code   {:bg [40 40 50] :color [220 220 220]}}})
```

When a sub-table is absent, the parent aspect's `:color` applies. The hardcoded
`code_bg = {60, 60, 70, 255}` in `markdown.draw` becomes the fallback used only
when the host aspect has no `:code :bg`.

## Implementation

### `src/redin/markdown/parser.odin`

```odin
Block_Kind :: enum u8 { Paragraph, Heading }

Block :: struct {
    kind:  Block_Kind,
    level: u8,        // 1..6 for Heading, 0 for Paragraph
    spans: []Span,
}

Span_Style :: enum u8 { Regular, Bold, Italic, Bold_Italic, Code }
```

`parse` flow:

1. `split_paragraphs` (unchanged) splits on blank lines.
2. For each paragraph, peek at the first non-whitespace byte. If `#`, count
   leading `#`s (clamp 6), require a following space, build a Heading block.
   Strip trailing `#`s and whitespace; pass remainder through `parse_inline`.
3. Otherwise build a Paragraph block as today.

`parse_inline` is rewritten as a small recursive walker that, for each
emphasis match, calls itself on the inner slice and merges the inner spans'
styles with the outer style:

| Outer     | Inner   | Result        |
|-----------|---------|---------------|
| Bold      | Italic  | `Bold_Italic` |
| Italic    | Bold    | `Bold_Italic` |
| Bold      | Code    | `Code` (unchanged — code wins) |
| Italic    | Code    | `Code` |
| any       | Regular | outer style   |

`Bold_Italic ∘ Bold` and `Bold_Italic ∘ Italic` collapse back to `Bold_Italic`.

### `src/redin/markdown/render.odin`

- `font_for` adds a `.Bold_Italic` arm using `font.get(base, .Bold_Italic)` —
  the underlying chain falls back to Bold when no Bold-Italic face is loaded.
- `layout` accepts `blocks []Block` and a per-block size resolver. For each
  block, the resolver returns the effective `font_size` (and weight). Heading
  blocks use the `:h<level>` aspect when present, otherwise the scale table
  above. Paragraph blocks keep the current behavior (use `base_font_size`).
- `draw` reads per-style overrides from a small struct passed in by
  `runtime.draw_text`:

```odin
Style_Theme :: struct {
    base_color:  rl.Color,
    bold_color:  rl.Color,    // == base_color when no override
    italic_color: rl.Color,
    code_color:  rl.Color,
    code_bg:     rl.Color,    // hardcoded fallback if unset
}
```

Code spans use `code_color` for text and `code_bg` for the rectangle.
`Bold_Italic` uses `bold_color` — the bold override is the structurally
nearest match for a span where bold is the outer wrapper. Italic-color
overrides apply only to pure italic spans. (If users later need a separate
bold-italic color, a fourth sub-table can be added without breaking the
existing schema.)

### `src/redin/types/theme.odin`

```odin
Style_Override :: struct {
    color: [3]u8,        // {0,0,0} = inherit
    bg:    [4]u8,        // {0,0,0,0} = inherit; meaningful only for code
    set:   bool,         // distinguishes "explicit black" from "absent"
}

Theme :: struct {
    // ... existing fields
    bold:   Style_Override,
    italic: Style_Override,
    code:   Style_Override,
}
```

The `set` flag carries "this sub-table was provided" so that explicitly setting
`color [0 0 0]` doesn't read as "inherit". Without it the `bg [0 0 0 0]` zero
sentinel would also be ambiguous for the code background.

### `src/redin/bridge/bridge.odin`

`lua_to_theme` parses three new optional sub-tables:

```odin
t.bold   = lua_get_style_override(L, props_idx, "bold")
t.italic = lua_get_style_override(L, props_idx, "italic")
t.code   = lua_get_style_override(L, props_idx, "code")
```

`lua_get_style_override` returns `set: true` only if the requested key resolves
to a Lua table.

### `src/redin/render.odin`

`draw_text` (markdown branch) builds a `Style_Theme` from the host aspect and
its overrides, then forwards it into `markdown.draw`. Heading per-level lookups
hit the same theme map already passed in.

## Testing

### Parser unit tests (`src/redin/markdown/parser_test.odin`)

- `# foo` → 1 block, kind=Heading, level=1, single Regular span "foo".
- `###### foo` → level=6.
- `####### foo` → 7 `#`s → still level 6 with leading `#` literal? CommonMark
  treats it as a paragraph (no space after first 6). Match that — emit
  Paragraph.
- `## foo ##` → level=2, span "foo" (trailing `#`s and surrounding space
  stripped).
- `# **bold** title` → level=1, spans: Bold "bold", Regular " title".
- `**a _b_ c**` → 3 spans: Bold "a ", Bold_Italic "b", Bold " c".
- `_a **b** c_` → 3 spans: Italic "a ", Bold_Italic "b", Italic " c".
- `**a `code` b**` → 3 spans: Bold "a ", Code "code", Bold " b" (code wins).
- Empty input → 0 blocks.

### UI test (`test/ui/markdown_app.fnl` + `test_markdown.bb`)

Extend the existing app with a heading + nested-style sample:

```fennel
[:text {:id :md :aspect :body :markdown true}
  "# Heading

   This has **bold _and italic_** plus `code`."]
```

New assertions:

- `find-element {:id :md}` exists.
- The text node's `rect` height is ≥ ~3× the base line height (heading + 2
  paragraph lines, rough sanity).
- A regression check: rendering does not crash for these strings.

(No pixel-diff — visual fidelity is verified by eye via `/screenshot`.)

### Runtime tests

No Fennel-side change required. The theme schema is parsed in Odin; new
sub-tables are forwarded through `set-theme` opaquely.

## Docs

- `docs/core-api.md`: under the `:markdown` line, add a sentence covering
  headings (`#…######`), nested emphasis, and the per-style theme overrides.
- `docs/reference/theme.md`: document `bold` / `italic` / `code` sub-tables.

## Out of scope (still tracked under #102)

- Lists (`-`, `1.`).
- Triple-backtick code blocks.
- Links (`[text](url)`).
- Inline images (`![alt](url)`).
- Tables (GFM `| col |`).
- Per-idx markdown layout cache.
- CJK / non-ASCII word breaking.
- Streaming agent writes.
