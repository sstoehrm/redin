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
| `scroll` | Not yet implemented |
| `grid` | Not yet implemented |
| `spacer` | Not yet implemented |
| `divider` | Not yet implemented |

---

## Frame format

A frame is a nested array: `[tag, attrs, ...children]`.

| Position | Content |
| -------- | ------- |
| 1 | Element tag (keyword string, e.g. `:vbox`) |
| 2 | Attributes table (always present, `{}` if none) |
| 3+ | Children (nested frames) or string content (for `text`) |

```fennel
[:vbox {:gap 8}
  [:text {:aspect :body} "hello"]
  [:button {:click :event/save :aspect :button} "Save"]]
```

### Nested list flattening

A child whose first element is itself a table (not a string tag) is automatically spliced into the parent's children. This means loops and multi-element component functions need no wrapper container.

```fennel
[:vbox {:gap 8}
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

> **Status:** The canvas type exists in the host but rendering is placeholder only.

```fennel
[:canvas {:provider :line-chart :width 400 :height 200}]
```

---

### `spacer` (not yet implemented)

Flexible empty space. Expands along the parent's main axis, pushing siblings apart.

**Required attrs:** none
**Optional attrs:** none beyond the common set.

```fennel
[:hbox {:gap 8}
  [:text {:aspect :label} "File"]
  [:spacer {}]
  [:text {:aspect :muted} "Saved"]]
```

---

### `divider` (not yet implemented)

A visual separator line. Automatically orients based on the parent container direction.

**Required attrs:** none
**Optional attrs:** none beyond the common set.

```fennel
[:vbox {:gap 4}
  [:text {:aspect :label} "Section A"]
  [:divider {:aspect :divider}]
  [:text {:aspect :label} "Section B"]]
```

---

## Container elements

Container elements hold child frames. Children are passed as positional arguments after the attrs table.

---

### `stack`

All children receive the full available space and overlap. Use for layering (e.g., a canvas background behind content).

**Required attrs:** none
**Optional attrs:** none beyond the common set.

```fennel
[:stack {}
  [:canvas {:provider :dot-grid :width "full" :height "full"}]
  [:vbox {:gap 16}
    [:text {:aspect :heading} "App title"]]]
```

---

### `hbox`

Lays out children in a horizontal row, left to right.

**Required attrs:** none

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `gap` | px number | `0` | Space between children. |
| `overflow` | string | -- | Overflow handling strategy. |
| `layoutX` | `"left"` \| `"center"` \| `"right"` | `"left"` | Horizontal alignment. |
| `layoutY` | `"top"` \| `"center"` \| `"bottom"` | `"center"` | Vertical alignment. |

```fennel
[:hbox {:gap 8}
  [:image {:src "assets/avatar.png" :width 32 :height 32}]
  [:text {:aspect :body} "Alice"]]
```

---

### `vbox`

Lays out children in a vertical column, top to bottom.

**Required attrs:** none

**Optional attrs:** identical to `hbox` -- `gap`, `overflow`, `layoutX`, `layoutY`.

`layoutX` affects horizontal (cross-axis) alignment; `layoutY` affects vertical (main-axis) alignment.

```fennel
[:vbox {:gap 12}
  [:text {:aspect :heading} "Settings"]
  [:hbox {:gap 8}
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
  [:hbox {:gap 8}
    [:text {:aspect :heading} "Dashboard"]]

  (when (subscribe :modal-open?)
    [:modal {:aspect :overlay}
      [:vbox {:gap 12}
        [:text {:aspect :heading} "Delete item?"]
        [:hbox {:gap 8}
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
      [:vbox {:gap 2}
        [:button {:click :event/new-file :aspect :button} "New File"]
        [:button {:click :event/open-file :aspect :button} "Open..."]
        [:button {:click :event/quit :aspect :button} "Quit"]]])]
```

---

### `scroll` (not yet implemented)

A scrollable viewport. Clips its child and reveals it via scroll position.

**Constraint: exactly 1 child.**

**Required attrs:** none

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `direction` | `"vertical"` \| `"horizontal"` \| `"both"` | `"vertical"` | Scrollable axes. |
| `offset` | `[x y]` | `[0 0]` | Current scroll position in pixels. |

```fennel
[:scroll {:direction "vertical" :height 300}
  [:vbox {:gap 8}
    (icollect [_ item (ipairs items)]
      [:text {:aspect :body} item.label])]]
```

---

### `grid` (not yet implemented)

A two-dimensional grid layout. Children fill cells left-to-right, wrapping to the next row.

**Required attrs:** `cols`

**Optional attrs:**

| Attribute | Type | Default | Notes |
| --------- | ---- | ------- | ----- |
| `cols` | number | -- | Number of columns. **Required.** |
| `gap` | px number | `0` | Uniform gap between cells. |
| `row-gap` | px number | value of `gap` | Row spacing override. |
| `col-gap` | px number | value of `gap` | Column spacing override. |

```fennel
[:grid {:cols 3 :gap 16}
  (icollect [_ item (ipairs items)]
    [:text {:aspect :body} item.name])]
```

---

## Validation rules

The frame validator checks the following. Invalid frames are rejected before reaching layout.

| Rule | Detail |
| ---- | ------ |
| **Known tag** | The tag must be one of the registered element names. |
| **Required attributes present** | `image` needs `src`; `canvas` needs `provider`; `input` needs `value`; `button` needs `click`; `grid` needs `cols`. |
| **No visual properties** | `bg`, `color`, `border`, `font-size`, `weight`, `radius`, `border-width`, `opacity` are rejected on any element. |
| **Leaf nodes have no children** | `text`, `image`, `input`, `button`, `spacer`, `divider`, `canvas` must not have child frames. |
| **`scroll` has exactly 1 child** | Zero children or more than one child is an error. |
| **`modal` and `popout` not at root** | Both must be nested inside a container element. |
