# html2redin — HTML+CSS to redin converter

**Date:** 2026-08-19
**Status:** Approved design
**Spec figure:** `.blend/specs/2026-08-19-html2redin.edn` (serve with `simpleviz`)

## Purpose

A one-shot scaffolding tool: convert an HTML+CSS mockup (real-world,
best-effort) into redin structures — a Fennel view fragment and a theme
map — that a developer pastes into an app and edits from there. The
tool is dev-time only; nothing ships in the framework or binary.

**Non-goals:** round-tripping (redin → HTML), HTML as an ongoing
authoring format, runtime HTML rendering, pixel-exact fidelity for CSS
features redin has no equivalent for (grid, floats, absolute
positioning).

## Tool shape

Pure Babashka, no external dependencies, at `tools/html2redin/`:

```
tools/html2redin/
  html2redin.bb        CLI entry
  src/                 one file per stage (bb classpath via bb.edn)
  test/                per-stage unit tests + golden end-to-end fixture
```

```bash
bb tools/html2redin/html2redin.bb page.html [-c extra.css]... [-o prefix]
```

- CSS sources, in cascade order: external `-c` files, then
  `<link rel="stylesheet">` resolved relative to the HTML file (missing
  file → warning), then `<style>` blocks in document order.
- Output: `<prefix>-view.fnl` (a single view expression) and
  `<prefix>-theme.fnl` (a map ready for `(theme-mod.set-theme …)`).
  Without `-o`, both print to stdout in that order, separated by a
  comment line.
- All diagnostics go to stderr, one line each, with source line
  numbers. Exit 0 unless the HTML is unreadable/unparseable (exit 1).

## Pipeline

Staged, each stage a pure function (see spec figure):

```
input.html ─→ HTML parser ──→ element tree ─┐
styles.css ─→ CSS parser ──→ rule list ─────┴→ cascade resolver
                                                  │
                                            styled tree
                                            (elements + resolved style maps)
                                              │        │
                                        node mapper  theme synthesizer
                                              │        │
                                              └→ Fennel emitter → view.fnl + theme.fnl
```

A shared warnings collector receives entries from every stage.

## HTML subset

Lenient hand-rolled tokenizer/parser:

- Elements, attributes (double-quoted, single-quoted, unquoted),
  text nodes, comments, void elements, raw-text `<style>`.
- Entities: `&amp; &lt; &gt; &quot; &apos;` plus numeric
  (`&#NN;`, `&#xNN;`); other named entities pass through with warning.
- Unclosed tags close when their parent closes.
- Skipped with a warning: `<head>` metadata (`title`, `meta`, `link`
  other than stylesheets), `script`, `svg`, `iframe`, `video`, `audio`,
  `canvas` (HTML canvas has no relation to redin `:canvas`).

## CSS subset

**Selectors** — supported: type (`div`), class (`.card`), id (`#top`),
compound (`div.card`), descendant (space), child (`>`), grouping
(comma), pseudo-classes `:hover`, `:focus`, `:active` on the rightmost
compound. Anything else (attribute selectors, siblings, `:nth-*`,
pseudo-elements, `@media`, `@import`) — rule skipped with warning.

**Cascade** — standard specificity `(id, class, type)` with source
order as tiebreaker; `!important` respected within the subset.
Inherited when not set: `color`, `font-size`, `font-family`,
`font-weight`, `line-height`, `text-align`.

**Shorthands expanded:** `margin`, `padding`, `border`,
`border-radius` (single value), `background` (color only), `font`
(size/weight/family), `gap`.

**Property mapping:**

| CSS | redin |
| --- | --- |
| `display: flex` + `flex-direction: row` | container becomes `:hbox` |
| `display: block/flex(column)/…` | `:vbox` |
| `display: none` | subtree dropped, warning |
| `gap` | `:gap N` |
| `margin` | `:margin [t r b l]` on leaf nodes; on containers: warning, dropped |
| `padding` | theme `padding [t r b l]` |
| `width`/`height` | `px` number; `100%` → `:full`; other %/auto → warning |
| `justify-content` + `align-items` | `:layout` anchor (start/center/end on both axes → the nine anchors) |
| `overflow(-y/-x): auto\|scroll` | `:overflow :scroll-y` / `:scroll-x` |
| `background-color` | theme `bg` |
| `color` | theme `color` |
| `border` (`-color`, `-width`) | theme `border`, `border-width` |
| `border-radius` | theme `radius` |
| `font-size` | theme `font-size` |
| `font-weight` | theme `weight` (`≥600` → 1, else 0) |
| `font-family` | theme `font` (first family name) |
| `line-height` (unitless) | theme `line-height` |
| `opacity` | theme `opacity` |
| `box-shadow` | theme `shadow [x y blur [r g b a]]` |
| `text-align` | `:layout` on `:text` |
| `position: absolute/fixed/sticky` | treated static, warning |
| `display: grid` | `:vbox`, warning |

**Colors:** `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, and the
16 basic named colors. **Units:** `px` native; `rem` × 16; `em`, `pt`,
`vh`, `vw`, `%` (except `width/height: 100%`) — warning, property
dropped.

## Element mapping

| HTML | redin |
| --- | --- |
| `div section main article aside nav header footer form ul ol li fieldset` | `:vbox` / `:hbox` per resolved `display`/`flex-direction` |
| `h1`–`h6`, `p`, `span`, `a`, `label`, `strong`, `em`, `li` (text-only) | `:text` — inline children flattened to one string; mixed inline markup flattens with warning |
| `button`, `input[type=button\|submit]` | `:button` (label from text content or `value`) |
| `input` (text-like types), `textarea` | `:input` (`placeholder`, `value` carried over; textarea warns: single-line field) |
| `img` | `:image` (size from attrs or CSS) |
| `table` | best-effort `:vbox` of `:hbox` rows (cells become cell-content nodes), warning |
| `br` | newline in the flattened text |
| `hr` | `:vbox` with height 1 and a border aspect |

`id` attributes are preserved as `:id :name`. Elements with `click`ish
semantics beyond `<button>` (e.g. `<a href>`) become `:text`; the
`href` is noted in a warning so the developer wires a `:click` by hand.

## Theme synthesis

Aspects come from class names: a class whose merged declarations
contain at least one mappable visual property becomes an aspect of the
sanitized same name (`.card` → `:card`); `:hover`/`:focus`/`:active`
rules become `#` variants (`card#hover`). Multi-class elements get a
composed aspect list (`[:card :highlight]`).

Because the cascade is per-element, an element's final visual style can
differ from its classes' own declarations (element selectors,
inheritance, id overrides). Reconciliation rule:

- If the element's resolved visual props equal exactly the merged
  declarations of its classes → it references the class aspect(s).
- Otherwise the tool emits a disambiguated aspect (`:card-2`,
  `:card-3`, …) carrying the element's actual resolved props.
- Styled elements with no classes get generated aspects (`:div-1`,
  `:h1-1`, …).

Output is therefore always faithful to the resolved cascade; class
names are used wherever they are truthful.

## Emission

Pretty-printed Fennel matching the style of `examples/` and the specs:
2-space indent, one child per line for containers, attrs map inline
when short. The view fragment is one expression suitable for pasting
into a `main_view`. The theme fragment is one map literal.

## Warnings

One stderr line per event: `page.html:12 warning: <svg> skipped`,
`styles.css:40 warning: selector "a ~ b" not supported — rule skipped`,
`styles.css:8 warning: margin on container .row dropped (redin has :gap/:padding)`.
Never fatal; the tool always produces output for parseable HTML.

## Testing

TDD throughout (bb, no framework — small assert helpers shared by the
tool's tests):

- Unit tests per stage: tokenizer, CSS parser, selector matching +
  specificity, cascade/inheritance/shorthands, node mapping, theme
  reconciliation, emitter formatting.
- One golden end-to-end fixture: `test/fixtures/sample.html` +
  `sample.css` → checked-in expected `view.fnl` / `theme.fnl`, compared
  verbatim.
- CI: a `bb` step running the tool's test runner, added to `test.yml`.

Follow-up (not v1): a UI round-trip test that runs the emitted view in
the dev binary and asserts rects via `/frames`.

<!-- TODO: integrate html2redin components into the project concept graph (blend:deduce) — skipped at spec approval, 2026-08-19 -->
