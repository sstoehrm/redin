# Theme Reference

Reference for the aspect/theme system in redin.

---

## Overview

The theme is a global flat map: `keyword -> property-table`. Elements reference aspects by name; they never carry visual properties directly.

```fennel
{:button        {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16]}
 :button#hover  {:bg [94 105 126]}
 :danger        {:bg [191 97 106] :color [236 239 244]}}
```

**Rule:** Visual properties belong in the theme only, never on elements directly.

---

## Setting a theme

Call `redin.set_theme` once at startup (typically in `theme.fnl`). The host parses theme data into native `Theme` structs for direct use during rendering.

```fennel
(redin.set_theme
  {:surface       {:bg [46 52 64] :padding 16}
   :heading       {:font-size 24 :color [236 239 244] :weight :bold}
   :button        {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16]}
   :button#hover  {:bg [94 105 126]}})
```

The theme can also be replaced at runtime via the dev server:

```
PUT /aspects   {"button": {"bg": [76, 86, 106], "color": [236, 239, 244]}}
```

PUT replaces the entire theme.

---

## Custom fonts (font-face)

Register custom fonts via a `:font-face` block in the theme. Each font name maps to a table of style variants (regular, bold, italic) pointing to .ttf file paths.

```fennel
(redin.set_theme
  {:font-face {:my-font    {:regular "assets/MyFont-Regular.ttf"
                             :bold    "assets/MyFont-Bold.ttf"}
               :icon-font  {:regular "assets/Icons.ttf"}}
   :heading   {:font :my-font :font-size 24 :weight :bold}
   :body      {:font :sans :font-size 14}
   :code      {:font :mono :font-size 13}})
```

`:font-face` is not an aspect -- it's processed separately to load font files before the theme is applied. Font files are loaded via Raylib's `LoadFont`.

Paths are validated before load: they must be relative (no leading `/`), contain no `..` segments, and no NUL bytes. Rejected paths are logged but don't abort the theme — the rest still applies. This matters because themes can come from `PUT /aspects` as well as Fennel code; the check keeps arbitrary filesystem paths out of the font loader regardless of source.

### Bundled fonts

Three font families are bundled in the binary and available without `:font-face`:

| Name | Font | Styles |
|------|------|--------|
| `sans` | Inter | Regular, Bold |
| `mono` | Fira Code | Regular, Bold |
| `serif` | Noto Serif | Regular, Bold |

`sans` is the default -- elements without a `:font` property use it.

### Fallback

If a requested font or style isn't found, the system falls back:
1. Regular style of the same font
2. Default font (sans) with the requested style
3. Default font Regular

---

## Theme struct

The host-side `Theme` struct (in `src/host/types/theme.odin`) defines the properties available per aspect:

| Property | Type | Notes |
| -------- | ---- | ----- |
| `bg` | `[r g b]` 0--255 | Background fill color |
| `color` | `[r g b]` 0--255 | Foreground / text color |
| `padding` | `[t r b l]` | Inner spacing, four sides |
| `border` | `[r g b]` 0--255 | Border stroke color |
| `border_width` | u8 | Border stroke thickness |
| `radius` | u8 | Corner rounding radius |
| `weight` | u8 | 0=normal, 1=bold, 2=italic |
| `font_size` | f16 | Font size in pixels (fractional) |
| `line_height` | f32 | Ratio of font size (e.g. 1.5); 0 = default (`font_size + 4`) |
| `font` | string | Font name (e.g. "sans", "mono", "serif", or custom) |
| `opacity` | f32 | Element transparency, 0--1 |
| `shadow` | struct | `{x, y, blur, color[r g b a]}` — drop shadow |
| `text_align` | enum | NodeInput vertical alignment: `:top`, `:center`, `:bottom`, `:auto` (default). `:auto` centres single-line inputs and top-aligns multi-line. |

Weight values: 0 = normal (default), 1 = bold, 2 = italic.

---

## Which elements consume which properties

Properties not consumed by an element are ignored silently. The consumption matrix is defined in `src/runtime/theme.fnl`.

```
            bg  color  border  font  padding  radius  border-w  opacity  shadow
text         .    x      .      x      .        .       .         x       .
image        .    .      .      .      .        .       .         x       .
hbox         x    .      .      .      x        .       .         x       x
vbox         x    .      .      .      x        .       .         x       x
input        x    x      x      x      x        x       x         x       .
button       x    x      .      x      x        x       .         x       x
modal        x    .      .      .      .        .       .         x       .
popout       x    .      x      .      x        x       x         x       x
canvas       x    .      x      .      x        x       x         x       x
```

Column key: `x` = consumed, `.` = ignored. `font` covers `font-size`, `weight`, `line-height`, `align`. `border-w` = `border-width`.

---

## Aspect composition

An element can reference a single aspect keyword or a list of aspect keywords. Multiple aspects merge left-to-right: later entries override earlier ones.

```fennel
[:button {:aspect [:button :danger] :click :event/delete} "Delete"]
;; Start with :button props, overlay :danger props
```

The `aspect` attribute accepts:

- A single keyword: `{:aspect :button}`
- A list of keywords: `{:aspect [:button :danger]}`

Missing aspects resolve to `{}` -- no error is raised.

---

## State variants

State variants use `#` notation. The renderer resolves variants by appending `#suffix` to each aspect name. Define only the properties that change; all other properties are inherited from the base aspect.

| State    | Suffix       | Trigger             |
| -------- | ------------ | ------------------- |
| hover      | `#hover`      | Cursor over element                    |
| focus      | `#focus`      | Keyboard focus                         |
| active     | `#active`     | Mouse button down                      |
| disabled   | `#disabled`   | Disabled element                       |
| drag-start | `#drag-start` | Node is being dragged                  |
| drag       | `#drag`       | Compatible drag hovers over drop target |

```fennel
{:button        {:bg [76 86 106] :color [236 239 244]}
 :button#hover  {:bg [94 105 126]}}
;; On hover: bg changes to [94 105 126], color stays [236 239 244]
```

### Composition + state merge order

For `{:aspect [:button :danger]}` when hovered, the merge sequence is:

1. Resolve `:button`
2. Merge `:danger` (overlays `:button`)
3. Merge `:button#hover` if it exists
4. Merge `:danger#hover` if it exists

Base aspects are applied first, then state variants for each in the same order.

---

## Naming conventions

Aspects should be named by role, not by appearance.

| Category    | Examples |
| ----------- | -------- |
| Surfaces    | `surface` `surface-alt` `surface-raised` |
| Typography  | `heading` `subheading` `body` `caption` `label` `mono` |
| Interactive | `button` `input` |
| Status      | `danger` `warning` `success` `info` `muted` |
| Structure   | `overlay` |

---

## Validation

```fennel
(aspect.validate theme)
;; => {:ok true}
;; or {:ok false :errors [{:aspect :button :property :bg :message "expected [r g b]"}]}
```

Validation is implemented in `src/runtime/theme.fnl`. Checks include:

| Check | Rule |
| ----- | ---- |
| Color format | `bg`, `color`, `border`, `cursor`, `selection`, `placeholder`, `scrollbar` must be `[r g b]` or `[r g b a]` with channels 0--255. `:selection` controls the highlight color for both `:input` nodes (original consumer) and `:text` nodes (text selection, added in this release). |
| Font type | `font` must be a string |
| | `weight` must be `"normal"` or `"bold"` |
| | `align` must be `"left"`, `"center"`, or `"right"` |
| Opacity range | `opacity` must be a number in `[0, 1]` |
| Numeric types | `font-size`, `radius`, `border-width`, `line-height`, `scrollbar-width`, `scrollbar-radius` must be numbers |
| Shadow format | `shadow` must be `[x y blur [r g b a]]` |
| Padding format | `padding` must be a number, `[v h]`, or `[t r b l]` |
