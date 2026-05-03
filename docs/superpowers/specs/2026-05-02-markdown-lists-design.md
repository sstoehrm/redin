# Markdown lists — design

## Goal

Add bullet and ordered lists with up to-N nesting to the markdown renderer
(`:text {:markdown true}`). One of the deferred items in #102. Tracker
(to be filed at start of implementation): see issue commits.

The renderer already supports paragraphs, headings, and nested inline
styles. Lists round out the most-used CommonMark block-level features
short of code blocks and tables.

## Public surface

### Syntax

```
- bullet item
- another bullet
  - nested at +2 spaces
    - and so on, 2-space step
* also bullet (`-`, `*`, and `+` all accepted)
+ also bullet
1. ordered item
2. second ordered
1) also ordered (`<n>.` and `<n>)` both accepted)
```

Rules:

- Each list-item line is its own block.
- Items are single-paragraph — no multi-line continuation.
- Tight only — a blank line ends the list. Two adjacent lists with a blank
  line between are rendered as separate lists.
- Mixed markers within a level are fine (`- a` followed by `* b` produces
  two bullet items in the same list).
- Ordered numbers render verbatim. `5. a / 6. b` renders `5. / 6.`. `1. a /
  1. b / 1. c` renders `1. / 1. / 1.`. No auto-renumbering — simpler than
  CommonMark and matches what the user sees in the source.
- Nesting: a child item must have ≥ 2 more spaces of leading whitespace
  than its parent. Nesting depth = `floor(leading_spaces / 2)`.

### Rendering

- Bullet glyph: `•` (U+2022).
- Ordered marker: literal `<n>.` / `<n>)` from the source.
- 8px gap between marker and item content.
- 24px indent per nesting level (constant in v1).
- Marker color and font: same as the item's content (no separate theme
  hook in v1).
- Item content uses the host aspect's `font_size`, `line_height`, and
  per-style overrides (`:bold` / `:italic` / `:code`) exactly as for
  paragraphs.

## Implementation

### `src/redin/markdown/parser.odin`

Extend the existing types:

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

`level` is reused: heading level for headings, nesting depth for list
items, 0 for paragraphs. `ordered` and `marker` are zero/empty for non-
list blocks.

A new helper:

```odin
// Returns (level, ordered, marker_string, body, true) when `line` opens
// with optional spaces, then a list marker, then a single space, then
// content. Levels: floor(leading_spaces / 2). The `marker` returned for
// bullets is "•" (the rendered glyph). For ordered items it's the
// literal `<n>.` or `<n>)` from the source.
detect_list_item :: proc(line: string) -> (level: u8, ordered: bool,
                                            marker: string, body: string,
                                            ok: bool)
```

`parse` becomes:

1. Split source on blank lines (existing `split_paragraphs`).
2. For each chunk:
   - If the chunk's first line matches `detect_heading`, emit a single
     `Heading` block consuming the entire chunk. **This preserves the
     current behavior** where a heading absorbs any trailing lines in
     its chunk (e.g. `# title\nsubtitle text` parses as one heading
     today, and continues to do so).
   - Otherwise, walk lines top-down:
     - If the line matches `detect_list_item`, emit a `List_Item` block.
       The marker string is heap-allocated so it outlives the source
       slice (cleared with the rest of the parser allocations).
     - Otherwise, accumulate into a paragraph buffer. Flush as a
       `Paragraph` block when the next line starts a list item or when
       the chunk ends.

Mixed paragraph + list-item content within a single chunk works (no
blank line required between them). Headings remain chunk-greedy to
avoid silently changing the existing parser's output.

### `src/redin/markdown/render.odin`

Two constants:

```odin
LIST_INDENT_PX :: 24.0
LIST_MARKER_GAP_PX :: 8.0
```

`layout` per-block branch:

- For `List_Item` blocks, the layout cursor starts at
  `(level * LIST_INDENT_PX)`. Lay out the marker first (a single Regular
  span), advance the cursor by `marker_width + LIST_MARKER_GAP_PX`, then
  lay out the item's spans normally with the new starting `cursor_x` and
  the same word-wrap `max_width` (which still applies to the right
  margin).
- The marker is laid out as a `Span_Box` with a synthesised
  `Span_Style.Regular` and the marker text. It does not need to be
  represented in the parser's `[]Span` — it's a render-time addition.
- Continuation lines from word-wrap re-set `cursor_x` to the same
  indent (`level * LIST_INDENT_PX + marker_width + GAP`) so wrapped text
  aligns under the first character of the item content.

`draw` follows the same data — the marker box is drawn the same way as
any other span box.

### `Block_Params` and `Style_Theme`

No schema changes. List items use:

- `font_size` / `line_height` from `Block_Params[idx]` (paragraph values
  applied; renderer makes no special heading-vs-list distinction beyond
  what `build_markdown_params` already returns).
- Per-style colors from `Style_Theme` (item content honors `:bold` /
  `:italic` / `:code` overrides exactly as paragraphs do).

The marker color is `style.base_color`. No separate `:list-marker` aspect
in v1.

### `src/redin/render.odin`

`build_markdown_params` already returns paragraph defaults for any block
where `kind != .Heading`. List items will pick up the paragraph defaults
unchanged — no edits needed.

## Tests

### Parser unit tests

Append to `src/redin/markdown/parser_test.odin`:

- `test_bullet_list` — `- a\n- b\n- c` → 3 List_Items, all `level=0`,
  `ordered=false`, `marker="•"`.
- `test_ordered_list` — `1. a\n2. b\n3. c` → 3 List_Items, all `level=0`,
  `ordered=true`, markers `"1."`, `"2."`, `"3."`.
- `test_ordered_paren_marker` — `1) a\n2) b` → markers `"1)"`, `"2)"`.
- `test_ordered_no_renumber` — `5. a\n6. b` → markers `"5."`, `"6."`.
- `test_list_nested` — `- parent\n  - child\n  - sibling\n- back` → 4
  List_Items at levels 0, 1, 1, 0.
- `test_list_mixed_markers` — `- a\n* b\n+ c` → 3 bullet items, all
  level 0, all marker `"•"`.
- `test_list_blank_separates` — `- a\n\n- b` → two separate lists; the
  blank line forces `split_paragraphs` to produce two chunks, each with
  one item.
- `test_list_with_inline_bold` — `- **bold** item` → 1 List_Item with
  spans `[Bold "bold", Regular " item"]`.
- `test_list_then_paragraph_no_blank` — `- a\nplain text` → 1 List_Item
  + 1 Paragraph in the same chunk.

### UI test

Extend `test/ui/markdown_app.fnl` with a `:md-lists` node:

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

Add `md-lists-renders` to `test/ui/test_markdown.bb` asserting the rect
height is sensibly tall (≥ ~280px for the content at body font-size 24
× line-height 1.5 — 11 lines × ~36px ≈ 396px, conservative threshold
280 to absorb metric variance).

## Out of scope

Still tracked under #102:

- Multi-paragraph items (item content spanning blank lines).
- Lazy continuation lines (text without a marker absorbed into the
  current item).
- Loose lists (blank lines between items render with extra spacing).
- Checkbox task lists (`- [ ] todo`).
- Per-list theme aspects (`:list`, `:list-marker`, `:list-item`,
  configurable indent step) — small follow-up if users want it.

## Edge cases nailed down

- Empty input → 0 blocks (already covered by existing parser tests).
- A line that's only `-` (no trailing space): does NOT match
  `detect_list_item`. Treated as paragraph text.
- A line with leading spaces but no marker (e.g. `  text`): does NOT
  start a list item. Falls into the paragraph buffer of the current
  chunk. (No lazy continuation: this content is a literal indented
  paragraph line.)
- Tab indent is not supported in v1. `detect_list_item` accepts only
  ASCII space characters as leading indent. A line beginning with a
  tab does not match (tab is neither a space nor a list marker), so
  it falls through to the paragraph buffer. Document under the
  `:markdown` attribute that nesting indent must be ASCII spaces.
- Maximum nesting: u8 covers 0..255; we cap at 8 in the parser to bound
  pathological deep indent (returns `level = 8` for any deeper input).
- A bullet line whose content is empty (e.g. `- `): valid, emits a
  List_Item with empty spans.
