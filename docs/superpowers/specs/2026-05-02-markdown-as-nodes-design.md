# Markdown as nodes

**Status:** design
**Date:** 2026-05-02
**Branch:** `feat/markdown-nodes`
**Supersedes:** the abandoned approach on `feat/markdown-lists` (#102 / #105)

## Problem

The current `:text {:markdown true}` path (on `main`) dispatches in
`render.draw_text` to a dedicated parse → layout → draw pipeline in
`src/redin/markdown/` that is parallel to the normal text renderer. To
extend it to headings, lists, and per-style theming, the pipeline has
been growing its own parallel concepts (`Block_Kind`, `Block_Params`,
`Style_Override`) — a private mini-renderer.

The architectural cost of that direction has been compounding. We are
restarting with a different shape: lower markdown to ordinary redin
nodes, theme them with ordinary aspects, and only retain a single
narrow extension point in the text renderer (mixed-font word-wrap
inside one `:text` node).

## Goals

- A first-class `[:markdown {…} "source"]` element. The keyword `:text
  {:markdown true}` is removed (clean break — one example app + agent
  docs migrate in the same PR).
- Block structure (paragraphs, headings, list items, lists) is lowered
  to a regular subtree of `:vbox` / `:hbox` / `:text` nodes during
  bridge node-reading. The lowered subtree is what the rest of the
  framework — layout, render, input, dev server — sees.
- Inline emphasis (`**bold**`, `_italic_`, `` `code` ``) stays inside a
  single `:text` node, carried as pre-parsed inline spans on a private
  `NodeText` field. The text renderer learns one new branch: span-aware
  mixed-font word-wrap.
- Theme entries for markdown live under a `md/` prefix
  (`:md/h1`…`:md/h6`, `:md/body`, `:md/list`, `:md/list-item`,
  `:md/list-marker`, `:md/code`) so they cannot collide with user-app
  aspect names.
- Framework ships defaults for every `md/*` aspect via a new
  `default-theme` fallback layer in `src/runtime/theme.fnl`. Apps get
  readable markdown without theme config; user `theme.set-theme` calls
  override individual entries.
- v1 scope: paragraphs, inline emphasis, headings (`#`–`######`), flat
  unordered + ordered lists.

## Non-goals (deferred to follow-ups)

- Nested inline emphasis (`**bold _italic_**`) and the `Bold_Italic`
  font work that supports it.
- Nested lists.
- Triple-backtick code blocks.
- Block quotes.
- Links, images, tables.
- Multi-line list items (continuation indent).
- Streaming / incremental markdown renders.
- Per-region scoped themes (chosen `(α)` namespace prefix instead of
  `(γ)` scoped-theme attribute).
- `:agent :read` / `:agent :edit` on a `[:markdown]` element. The
  wrapper lowers to a `:vbox` with synthetic text children, neither
  of which carries the original source string in a place the agent
  channel can address. Agent-writable markdown content stays out of
  scope for v1; the agent example doc migrates by having the agent
  write into a plain `:text` node and a sibling `[:markdown]` reads
  the same `db.agent.reply` value via subscription.

## User-facing surface

```fennel
[:markdown {:aspect :card :id :reply :width :full :height 400
            :overflow :scroll-y}
  "# Title

A paragraph with **bold** and _italic_ and `code` text.

- first
- second"]
```

`[:markdown]` is a new top-level element keyword, not an attribute on
`:text`. Attributes:

| Attr | Notes |
|---|---|
| `:aspect` | Themes the **wrapper** (the lowered top node). Padding, bg, border around the whole markdown block. Ordinary user aspect — no `md/` prefix. |
| `:id` | Lands on the lowered wrapper node. `(find-element {:id ...})` returns it. |
| `:width`, `:height` | Sizing of the wrapper. |
| `:overflow` | Forwarded to the wrapper vbox. `:scroll-y` is the natural common case for tall blocks. |

Lowering always emits a `:vbox` wrapper carrying the user's
attributes (`:aspect`, `:id`, `:width`, `:height`, `:overflow`),
regardless of how many blocks the source produces. This keeps the
frame-tree shape predictable: `(find-element {:id ...})` always
returns a vbox, and the user's `:aspect` never collides with an
inner `:md/*` aspect on a single-block source.

## Lowering pipeline

Lowering is in **the bridge**, during `lua_flatten_node` (which
dispatches per Lua table and writes flat-array entries). When the
table's head keyword is `markdown`, the flattener takes a markdown-
specific branch *before* calling `lua_read_node` (which returns a
single Node and is the wrong shape for markdown's
one-table-becomes-many-nodes output):

1. Pulls the source string and wrapper attributes out of the Lua
   table.
2. Calls `markdown.parse(source)` → `[]Block`. Each `Block` carries
   `kind` (`Paragraph` / `Heading_N` / `List_Item` / `List_Group`) and
   pre-parsed `[]text.Span` for inline content.
3. Calls `markdown.lower(blocks, wrapper_attrs)` →
   `markdown.LoweredTree`. The lowered tree is a small synthetic tree
   of `Node` values + parent relationships, owned by the temp arena.
4. Feeds the lowered tree into a new bridge helper
   `bridge.flatten_subtree(tree, parent_idx)` that walks it DFS and
   emits flat-array entries (`nodes`, `paths`, `parent_indices`,
   `children_list`) using the same conventions as the existing Lua-
   table → flat-array path.

The split keeps the import direction acyclic: `bridge` imports
`markdown`; `markdown` does not import `bridge`. The synthetic tree
type lives in the `markdown` package alongside `lower`.

Allocations live in the per-frame `context.temp_allocator` arena —
same pattern as the existing markdown render path on `main`.

The lowered subtree is fully visible in `/frames` — the dev-server
snapshot shows whatever the renderer sees. This is a debug feature
(easier to inspect than a hidden internal representation), and a
documentation point (apps relying on `/frames` shape need updating).

### Block lowering shapes

| Block | Lowered shape |
|---|---|
| Paragraph | `[:text {:aspect :md/body :_inline-spans …} "…"]` |
| Heading 1–6 | `[:text {:aspect :md/h1…h6 :_inline-spans …} "…"]` |
| Unordered list | `[:vbox {:aspect :md/list} (item …) (item …)]` |
| Ordered list | same shape; marker text is `"1."`, `"2."`, … |
| List item | `[:hbox {:aspect :md/list-item} [:text {:aspect :md/list-marker} "•"] [:text {:aspect :md/body :_inline-spans …} "…"]]` |

`_inline-spans` is not a user-writable attribute — it is shorthand
here for "the bridge attaches the parsed `[]text.Span` to the emitted
`NodeText`'s `inline_spans` field." Users never see this.

V1 lowering caveats:

- **Flat lists only.** A list item is recognised only when a line
  begins (column 0, no indent) with `- `, `* `, or `<digit>. `. Any
  other indented or continuation line is parsed as ordinary paragraph
  text. No nested-list detection, no continuation merging.
- **Single-line list items.** Continuation indent is not supported.
- **Headings can carry inline emphasis.** `# Hello **world**` parses
  spans inside the heading; the heading text node gets `inline_spans`
  attached and renders with the heading aspect's metrics for the base
  span and bold variant for the emphasized run.

## Inline spans on text nodes

`types.NodeText` gains a private field:

```odin
inline_spans: []text.Span,  // nil = plain rendering. Non-nil = mixed-font wrap.
```

Set only by `markdown.lower_into`. Users have no way to set it from
Fennel/Lua. The existing `markdown: bool` field is removed.

`render.draw_text` branches:

```odin
if len(n.inline_spans) > 0 {
    text.span_layout_and_draw(n, rect, theme, font_size, font_name,
                              text_color, lh_ratio)
    return
}
// existing plain-text path
```

`text.span_layout_and_draw` is essentially the body of today's
`markdown.layout` + `markdown.draw` lifted into the `text` package,
generalised on the parent text node's metrics:

- Base font + size + line-height come from the text node's resolved
  aspect (`:md/h2` for an h2 heading, `:md/body` for a paragraph or
  list item).
- Bold / Italic spans look up the same font name with
  `font.style_from_weight` / `.Italic` — exactly today's behaviour, no
  new font work.
- Code spans look up `:md/code` from the theme to drive font (mono
  default), bg fill, and any horizontal padding. The `:md/code`
  resolved values are read once at draw time per text node.

## Theme entries and defaults

### Aspect inventory (v1)

| Aspect | Consumer |
|---|---|
| `:md/body` | paragraph + list-item content |
| `:md/h1` … `:md/h6` | heading text nodes |
| `:md/list` | outer vbox of a list |
| `:md/list-item` | hbox of marker + content |
| `:md/list-marker` | marker text styling |
| `:md/code` | inline code span styling, read by span renderer |

Inline `bold` and `italic` are not themed via aspects; they are font-
style overrides on the parent text node's aspect. Future: a power-user
extension could add `:md/bold-style` / `:md/italic-style` overrides if
needed — out of scope for v1.

### Default-theme fallback

A new `default-theme` map in `src/runtime/theme.fnl`. Aspect lookup
becomes:

```
user-theme[aspect]  →  default-theme[aspect]  →  empty
```

Framework registers `md/*` defaults at runtime startup, before the
user's app code runs. Users override with the existing
`(theme.set-theme {…})` API; missing entries inherit defaults.

Default values (rough; finalise during implementation):

- `:md/body` — 18px regular, body color, line-height 1.5.
- `:md/h1`/`h2`/`h3`/`h4`/`h5`/`h6` — 32 / 26 / 22 / 19 / 17 / 16 px,
  weight 1; h5/h6 italic.
- `:md/list` — small vbox gap, padding-left for indent.
- `:md/list-item` — hbox gap 8px between marker and content.
- `:md/list-marker` — body color, fixed-width column for marker
  alignment.
- `:md/code` — mono font, slightly dark bg, slight horizontal padding.

### Wrapper aspect

The user's `:aspect` on `[:markdown {:aspect :foo} ...]` themes the
**wrapper** vbox / single-block top node only. It is a normal user
aspect — no `md/` prefix.

## File / package layout

```
src/redin/text/
  spans.odin                 NEW — Span + Span_Style types (moved here from markdown)
  span_layout.odin           NEW — mixed-font wrap + draw (lifted from markdown.layout/draw)
  ...                         (existing files unchanged)

src/redin/markdown/
  parser.odin                EXTEND — heading block, list-item block; spans imported from text/
  parser_test.odin           EXTEND — headings + lists
  lower.odin                 NEW — markdown.lower(blocks, wrapper_attrs) -> LoweredTree
                              + LoweredTree synthetic-tree type
  lower_test.odin            NEW — source-string → LoweredTree shape assertions
  render.odin                DELETED — superseded by text/span_layout.odin

src/redin/types/view_tree.odin
  NodeText.markdown          REMOVED
  NodeText.inline_spans      NEW — []text.Span

src/redin/bridge/bridge.odin
  lua_flatten_node           dispatch on tag == "markdown" early →
                              parse + lower + flatten_subtree, return.
                              No change for non-markdown tags.
  lua_read_node              remove `:text {:markdown true}` branch and
                              the `if md, exists := ... { t.markdown = md }`
                              attr read.
  flatten_subtree            NEW — DFS-walk a markdown.LoweredTree and emit
                              into the same flat arrays the Lua-table path uses

src/redin/render.odin
  draw_text                  replace `if n.markdown { … }` with
                              `if len(n.inline_spans) > 0 { text.span_layout_and_draw(…) }`

src/runtime/theme.fnl
  default-theme              NEW — second-tier fallback map
  resolution                 user-theme → default-theme → empty
  startup                    register `md/*` defaults
```

Dependency direction: `text` has no markdown import. `markdown`
imports `text` for `Span`. `bridge` imports `markdown` for
`lower_into`. `render` imports `text` for `span_layout_and_draw`
(already imports `text` for `line_height`).

## Testing

### Parser (Odin)

`src/redin/markdown/parser_test.odin` — extend existing inline-span
tests with cases for:

- Headings 1 through 6, with and without inline emphasis.
- Unordered lists with `-` and `*` markers.
- Ordered lists with `1.` / `2.` / … markers.
- A heading followed by a paragraph followed by a list — three blocks.
- Edge cases: heading with trailing `#`s, list with stray indent,
  empty list.

### Lowering (Odin)

`src/redin/markdown/lower_test.odin`, new — for each test source,
run `parse` + `lower` and assert on the resulting `LoweredTree`:

- Number of nodes produced.
- Node kinds in DFS order.
- Parent relationships in the synthetic tree.
- Aspects on each node (`:md/h1`, `:md/body`, etc.).
- Inline spans attached to text nodes (count + style + text).
- Wrapper attribute pass-through (`:aspect`, `:id`, `:width`, etc.).

A separate test against `bridge.flatten_subtree` covers the
LoweredTree → flat-array projection (parent-index correctness, DFS
order, child lists). This stays small because most of the logic is
in `lower`; flattening is a mechanical walk.

### UI integration

`test/ui/markdown_app.fnl` — gains a heading and a list:

```fennel
[:markdown {:id :md :aspect :card :width :full :overflow :scroll-y}
  "# Title

A paragraph with **bold** and _italic_ and `code` inline.

Second paragraph after a blank line.
Soft break here
on the next line.

- first item
- second item
- third item"]
```

`test/ui/test_markdown.bb`:

- Assert the wrapper node exists at `:id :md`.
- Assert the lowered tree shape via `/frames` (counts, attrs).
- Screenshot `test/ui/artifacts/markdown_render.png`.

### Build + memory

- `odin build src/cmd/redin …` after every step that touches Odin.
- `--track-mem` smoke after lowering lands; allocations live in the
  per-frame arena, so the leak count should match `main`.

## Migration / docs / cleanup

- `:text {:markdown true}` is removed. The boolean field
  `NodeText.markdown` is removed. The bridge's parsing of that attr
  is removed.
- `docs/core-api.md` — drop the `markdown` row from the text
  attribute table; add a `:markdown` element section under
  "Elements" with attribute list and lowered-tree note.
- `docs/reference/elements.md` — same: drop the row, add the section.
- `docs/core-api.md` agent channel example — keep the writable
  `:reply` text node (agent target). Add a sibling `[:markdown]`
  element that reads the same `db.agent.reply` value via subscription
  and renders it formatted. The agent target stays a plain `:text`
  with `:agent :edit`; markdown is the read-side preview.
- `.claude/skills/redin-dev/SKILL.md` — node types list gains
  `:markdown`; the `:markdown true` text-attribute line is removed.
- `CLAUDE.md` — node types list gains `NodeMarkdown` if listed (only
  appears in the architecture section).
- `test/ui/markdown_app.fnl` — switch to `[:markdown ...]`, exercise
  heading + list.
- `test/ui/test_markdown.bb` — adjust assertions for the new tree
  shape.
