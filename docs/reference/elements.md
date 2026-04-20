# Element Reference

Reference for all element tags in redin frames.

## Implementation status

| Tag | Status |
| --- | ------ |
| `stack` | Implemented |
| `canvas` | Implemented |
| `vbox` | Implemented |
| `hbox` | Implemented |
| `input` | Implemented |
| `button` | Implemented |
| `text` | Implemented |
| `image` | Implemented |
| `popout` | Implemented |
| `modal` | Implemented |

---

## Frame format

A frame is a nested array: `[tag, attrs, ...children]`.

| Position | Content |
| -------- | ------- |
| 1 | Element tag (keyword string, e.g. `:vbox`) |
| 2 | Attributes table (always present, `{}` if none) |
| 3+ | Children (nested frames) or string content (for `text`) |

```fennel
[:vbox {}
  [:text {:aspect :body} "hello"]
  [:button {:click :event/save :aspect :button} "Save"]]
```

### Nested list flattening

A child whose first element is itself a table (not a string tag) is automatically spliced into the parent's children. This means loops and multi-element component functions need no wrapper container.

```fennel
[:vbox {}
  [:text {:aspect :heading} "Todos"]
  (icollect [_ item (ipairs items)]
    [:hbox {} [:text {} item.text]])]
```

Flattening is a single pass when the frame enters the pipeline.

---

## Common attributes

All elements accept these attributes.

| Attribute | Type | Notes |
| --------- | ---- | ----- |
| `id` | keyword or string | Identity for testing and dev server inspection |
| `aspect` | keyword or `[kw ...]` | Theme reference. Single keyword or composed list (merged left-to-right). |
| `width` | px number or `"full"` | Element width. `"full"` expands to available space. |
| `height` | px number or `"full"` | Element height. `"full"` expands to available space. |
| `visible` | boolean | `false` -- element is not laid out and takes no space. |

**Visual properties (`bg`, `color`, `border`, `font-size`, `weight`, `radius`, `border-width`, `opacity`) must never appear on elements.** They belong in the theme only.

---

## Leaf elements

Leaf elements have no children. The validator rejects children on any leaf except `text`, which takes a string as its last positional argument.

---

### `text`

Renders a string of text. The text content is the last positional argument, not an attribute.

**Required attrs:** none

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `wrap` | `"word"` \| `"char"` \| `"none"` | `"word"` | Line-wrapping strategy. |
| `selectable` | boolean | `true` | Set to `false` to opt the node out of mouse-selection. |

Typography (`font-size`, `weight`, `color`) comes from `aspect`.

```fennel
[:text {:aspect :body} "Hello, world"]

[:text {:aspect :mono} (tostring count)]
```

---

### `image`

Renders a texture loaded from a file path.

**Required attrs:** `src`

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `src` | string | -- | File path to the image. **Required.** |

```fennel
[:image {:src "assets/logo.png" :width 120 :height 40}]
```

---

### `input`

An editable text field. Drives its displayed value from the `value` attribute.

**Required attrs:** `value`

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `value` | string | -- | Current field content. **Required.** |
| `change` | keyword | -- | Event dispatched when the value changes. |
| `key` | keyword | -- | Event dispatched on key press (e.g. enter). |
| `placeholder` | string | `""` | Hint text shown when value is empty. |

Visual properties (`bg`, `color`, `border`, `radius`, `border-width`, `opacity`) come from `aspect`.

```fennel
[:input {:aspect :input
         :value (subscribe :search-query)
         :change :event/search-changed
         :placeholder "Search..."}]
```

---

### `button`

A clickable element with a text label. Dispatches an event on click.

**Required attrs:** `click`

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `click` | keyword | -- | Event dispatched on click. **Required.** |
| `label` | string | -- | Button text. Can also be passed as a child string. |

Visual properties come from `aspect`.

```fennel
[:button {:click :event/save :aspect :button} "Save"]

[:button {:click :event/cancel :aspect [:button :danger] :label "Cancel"}]
```

---

### `canvas`

An independent render region managed by a registered canvas provider. The provider owns its own draw loop and local state.

**Required attrs:** `provider`

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `provider` | keyword | -- | Name of a registered canvas provider. **Required.** |

The element's `width` and `height` define the render texture size. See the [canvas provider docs](canvas.md) for registration and lifecycle details.

```fennel
[:canvas {:provider :line-chart :width 400 :height 200}]
```

---

## Container elements

Container elements hold child frames. Children are passed as positional arguments after the attrs table.

---

### `stack`

All children receive the full available space and overlap. Use for layering (e.g., a canvas background behind content).

**Required attrs:** none

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `viewport` | `[[x y w h] ...]` | -- | Array of rects, one per child. Positions children absolutely relative to the window. |

Each viewport value can be:
- **px number** -- fixed pixels (e.g. `42`, `250`)
- **`:full`** -- full window dimension
- **Fraction keyword** -- `:M_N` resolves to `M/N` of the window dimension (e.g. `:1_2` = 50%, `:3_4` = 75%)

When `viewport` is set, the entry count must exactly match the child count. The viewport rect overrides any `width`/`height` on the child.

```fennel
;; Basic stack (no viewport) -- children overlap at full size
[:stack {}
  [:canvas {:provider :dot-grid :width "full" :height "full"}]
  [:vbox {}
    [:text {:aspect :heading} "App title"]]]

;; Viewport stack -- absolute positioning
[:stack {:viewport [[0 0 :full :full]
                    [:1_2 :1_2 :1_4 42]]}
  [:vbox {:aspect :surface} ...]
  [:hbox {:aspect :body} ...]]
```

---

### `hbox`

Lays out children in a horizontal row, left to right.

**Required attrs:** none

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `overflow` | `"scroll-x"` | -- | Clip + horizontal wheel scroll. Children must set `:width`. See Scrolling. |
| `layout` | anchor keyword (see below) | `"top_left"` | Child alignment along both axes. |

`:layout` takes one of nine two-axis anchors: `top_left`, `top_center`, `top_right`, `center_left`, `center`, `center_right`, `bottom_left`, `bottom_center`, `bottom_right`. For an hbox the horizontal component selects where the children *group* sits on the main axis; the vertical component selects how each child is aligned on the cross axis. For a vbox the roles swap. Unrecognized values log a warning and fall back to `top_left`.

Main-axis centering only takes effect when every child has an explicit size (a single fill child would absorb the extra space instead).

```fennel
[:hbox {}
  [:image {:src "assets/avatar.png" :width 32 :height 32}]
  [:text {:aspect :body} "Alice"]]
```

---

### `vbox`

Lays out children in a vertical column, top to bottom.

**Required attrs:** none

**Optional attrs:** identical to `hbox`. `overflow` is `"scroll-y"` (see Scrolling).

For a vbox, the horizontal component of `:layout` aligns each child across the row (cross axis), and the vertical component positions the children group within the container's height (main axis).

```fennel
[:vbox {}
  [:text {:aspect :heading} "Settings"]
  [:hbox {}
    [:text {:aspect :label} "Theme"]
    [:input {:aspect :input :value (subscribe :theme-name) :change :event/theme-changed}]]]
```

---

### `modal`

A full-screen overlay that blocks all interaction with content behind it.

**Required attrs:** none
**Optional attrs:** none beyond the common set.

Background color and opacity come from `aspect`.

```fennel
[:vbox {}
  [:hbox {}
    [:text {:aspect :heading} "Dashboard"]]

  (when (subscribe :modal-open?)
    [:modal {:aspect :overlay}
      [:vbox {}
        [:text {:aspect :heading} "Delete item?"]
        [:hbox {}
          [:button {:click :event/cancel :aspect :button} "Cancel"]
          [:button {:click :event/confirm :aspect [:button :danger]} "Delete"]]]])]
```

---

### `popout`

A container anchored to its parent that escapes parent clipping. Rendered in the overlay layer, positioned relative to the parent element. Use for dropdowns, tooltips, and context menus.

**Required attrs:** none

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `mode` | `"mouse"` \| `"fixed"` | `"mouse"` | Positioning mode. |
| `x` | number | -- | Fixed x position (when mode is `"fixed"`). |
| `y` | number | -- | Fixed y position (when mode is `"fixed"`). |

Visual properties come from `aspect`.

```fennel
[:vbox {}
  [:button {:click :event/open-menu :aspect :button} "File"]
  (when (subscribe :file-menu-open?)
    [:popout {:aspect :surface}
      [:vbox {}
        [:button {:click :event/new-file :aspect :button} "New File"]
        [:button {:click :event/open-file :aspect :button} "Open..."]
        [:button {:click :event/quit :aspect :button} "Quit"]]])]
```

---

## Scrolling

Attach `:overflow :scroll-y` to a vbox or `:overflow :scroll-x` to an hbox to clip its children to the container rect and enable wheel-driven scrolling on that axis. (Text nodes also accept both and scroll their own content inline.) Shift + vertical wheel is promoted to horizontal scroll for trackpads / mice without a lateral axis.

Child sizing rules differ by axis:

- **`scroll-y` on vbox** — children can omit `:height`. The renderer recurses through each unsized child to compute its natural height: text uses wrapped-line count × line height, nested vbox sums its children, nested hbox/stack takes the max. Explicit `:height` is honored when set.
- **`scroll-x` on hbox** — children **must** set `:width`. Intrinsic width is not inferred because it is ill-defined for wrapped text (the width is both input and output of measurement). Any child without a positive preferred width renders at zero width and a warning is printed to stderr.

Both modes draw a 4px translucent scrollbar along the trailing edge when content exceeds the container. Scroll offsets are stored per-element and persist across renders as long as the element's idx is stable.

```fennel
;; Chat log: variable-height message bubbles
[:vbox {:height :full :overflow :scroll-y}
  (icollect [_ msg (ipairs messages)]
    [:vbox {:aspect :bubble}
      [:text {:aspect :body} msg.text]])]

;; Tab bar: horizontal list of fixed-width tabs
[:hbox {:width 600 :height 36 :overflow :scroll-x}
  (icollect [_ tab (ipairs tabs)]
    [:button {:aspect :tab :width 140 :height 32
              :click [:event/select-tab tab.id]} tab.label])]
```

---

## Validation rules

The frame validator checks the following. Invalid frames are rejected before reaching layout.

| Rule | Detail |
| ---- | ------ |
| **Known tag** | The tag must be one of the registered element names. |
| **Required attributes present** | `image` needs `src`; `canvas` needs `provider`; `input` needs `value`; `button` needs `click`. |
| **No visual properties** | `bg`, `color`, `border`, `font-size`, `weight`, `radius`, `border-width`, `opacity` are rejected on any element. |
| **Leaf nodes have no children** | `text`, `image`, `input`, `button`, `canvas` must not have child frames. |
| **`modal` and `popout` not at root** | Both must be nested inside a container element. |
