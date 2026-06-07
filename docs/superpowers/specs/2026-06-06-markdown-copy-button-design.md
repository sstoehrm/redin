# Markdown copy button + non-selectable lowered text (#112)

**Date:** 2026-06-06
**Issue:** [#112](https://github.com/sstoehrm/redin/issues/112) — Markdown lowered text cannot be selected or copied correctly

## Problem

Markdown lowering turns `[:markdown {…} "source"]` into a synthetic subtree of
vbox/hbox/text nodes. Two defects make the rendered text un-copyable yet
deceptively interactive:

1. **Path collision.** `flatten_subtree` (`src/redin/bridge/bridge.odin`) gives
   every lowered node a copy of the wrapper's path. `find_node_by_path`
   (`src/redin/input/text_select.odin:260`) is a linear scan returning the
   *first* match, so a click on any markdown text resolves to the wrapper
   (a vbox), never the text node.
2. **Empty `content`.** Span-bearing `NodeText` (headings, body, list-item
   text) store their text in `inline_spans` and leave `content` empty. Every
   consumer of selection — hit-testing (`node_byte_offset_at`), highlight
   (`draw_selection_rects`), copy (`copy_selection`), and the `/selection`
   endpoint — reads `NodeText.content` with a **single-font** `compute_lines`.

Because lowered text still emits `Text_Select_Listener` (it isn't marked
non-selectable), the text *looks* selectable, but double-click, drag, Ctrl-A,
Ctrl-C, and `/selection` cannot return it.

## Chosen approach

Rather than build full span-aware partial-text selection (unique synthetic
paths + content backfill + mixed-font x↔byte mapping — large, high-risk), give
copyable markdown blocks a **copy button that puts the verbatim raw markdown
source on the system clipboard**, and make the lowered text **non-selectable**
so the broken affordance is gone.

This fully answers #112's complaint ("markdown text can't be copied") with a
small, low-risk change and leaves no misleading half-broken selection behind.

### Decisions

| Decision | Choice |
|---|---|
| Capability | Copy *whole block's* raw source (not partial selection) |
| API | Opt-in: `[:markdown {:copyable true} "source"]` |
| Default (`:copyable` absent/false) | Rendering unchanged — no button |
| Button placement | Right-aligned button row **above** the rendered content |
| Visibility | Always visible (no hover-reveal) |
| What is copied | The verbatim source string, exactly as authored |
| Lowered text selectability | `not_selectable = true` on **all** lowered text (independent of `:copyable`) |
| Clipboard mechanism | Host-side `rl.SetClipboardText`; new `copy_text` field on `NodeButton`; no Fennel round-trip |

## Components & data flow

### 1. Element + bridge (`src/redin/bridge/bridge.odin`)
- The markdown branch in `lua_flatten_node` already reads the `source` string
  and the wrapper attrs. Read one more attr, `:copyable` (bool, default
  false), and pass both `source` and `copyable` into `markdown.lower`.
- `flatten_subtree`'s per-node deep-copy pass clones the new `NodeButton.copy_text`
  into permanent storage (same treatment as `content`/`label`).

### 2. Lowering (`src/redin/markdown/lower.odin`)
- `Wrapper_Attrs` gains `copyable: bool`. `lower()` gains a `source: string`
  parameter (the raw markdown text).
- When `copyable` is true, emit — as the wrapper vbox's **first child** (before
  any content block, in DFS order) — a `NodeHbox` (`aspect = "md/copy-bar"`)
  that is **full width** (`width = :full`) with **horizontal anchor = right**,
  so its single child sits at the right edge. The hbox contains one
  `NodeButton`:
  - `aspect = "md/copy-button"`, `label = "Copy"`, `copy_text = source`,
    `click = ""` (no Fennel event).
- `flatten_subtree`'s `markdown_skips[wrapper] = len(tree.nodes)` stays correct
  automatically: the two extra nodes are counted in `len(tree.nodes)`, so the
  `/frames` sibling-skip needs no special-casing.
- Every `NodeText` emitted by lowering (`emit_text` for body/heading/list
  text, and the list marker in `emit_list_item`) sets `not_selectable = true`.

### 3. Types (`src/redin/types/view_tree.odin`)
- `NodeButton` gains `copy_text: string` (owned; freed by `clear_node_strings`
  like `label`/`content`).

### 4. Input layer (`src/redin/input/`)
- A button is **interactive** when `click != "" OR copy_text != ""` (today it
  keys on `click` only). This makes the copy button hit-testable / hover-able
  even though it has no Fennel event.
- On a button click, if `copy_text != ""`, call `rl.SetClipboardText(copy_text)`
  (the same primitive `copy_selection` uses at `src/redin/input/edit.odin:267`).
  If `click` is also set, the normal dispatch still happens; the copy button
  has no `click`, so it is a pure host-side action.
- The copy-on-click decision is factored into a small testable helper
  (e.g. `button_clipboard_text(n: NodeButton) -> (string, bool)`).

### 5. Theme (`src/runtime/markdown.fnl`)
- Ship default aspects in `M.install`, overridable like the rest of `md/*`:
  - `md/copy-bar` — the right-aligned row (padding only).
  - `md/copy-button` — `bg`, `color`, `radius`, `padding`, small `font-size`.

## Error / edge handling
- `:copyable` not a boolean → treat as false (no button), consistent with
  other optional-attr parsing.
- Empty source string → button still renders; copying an empty string is a
  no-op write, acceptable.
- `copy_text` lifetime mirrors other owned node strings: cloned in
  `flatten_subtree`, freed in `clear_node_strings`. No idx-keyed side table,
  so no `clear_frame` invalidation hazard.

## Testing (structural + unit; no clipboard read-back endpoint)
- **Odin unit — `src/redin/markdown/lower_test.odin`:**
  - `copyable = true` ⇒ wrapper's first child is the `md/copy-bar` hbox whose
    child is a `NodeButton` with `copy_text == source` and `label == "Copy"`.
  - `copyable = false` ⇒ no copy bar; first child is the first content block.
  - Every lowered `NodeText` has `not_selectable == true`.
- **Odin unit — input helper:** `button_clipboard_text` returns `(copy_text,
  true)` for a button with non-empty `copy_text`, `("", false)` otherwise.
- **UI — `test/ui/test_markdown.bb` / `test/ui/markdown_app.fnl`:**
  - A `:copyable true` block exposes the copy `button` node in `/frames`.
  - Clicking markdown body text leaves `/selection` at `{kind:"none"}`
    (selection is disabled on lowered text).
  - (No assertion on actual clipboard contents — out of scope, see non-goals.)

## Non-goals (v1)
- Partial / per-paragraph text selection of rendered markdown.
- Cross-block drag selection.
- "Copied!" visual feedback (needs transient per-node state + timer).
- Hover-reveal of the button (would feed hover state back into static lowering).
- A public `:copy` button attribute for app authors (the `copy_text` field is
  markdown-internal for now; it can back a documented attribute later).
- A `GET /clipboard` dev-server endpoint for end-to-end copy verification.

## Docs to update (same PR)
- `docs/core-api.md` — markdown attribute table: add `:copyable`.
- `docs/reference/theme.md` — `md/copy-bar`, `md/copy-button` aspects + consumers.
- `.claude/skills/redin-dev/SKILL.md` — markdown `:copyable` note in the node section.
- (No change to `docs/reference/elements.md` unless it tabulates markdown attrs.)
