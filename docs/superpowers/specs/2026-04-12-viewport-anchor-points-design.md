# Viewport Anchor Points

Extend the viewport rect format to include an anchor point that determines where coordinates attach and which direction the element grows from.

## Format

The viewport rect format changes from `[x y w h]` to `[anchor x y w h]` (always 5 elements). The old 4-element format is removed.

```fennel
[:stack {:viewport [[:top_left 0 0 :full :full]
                    [:bottom_center 0 0 :1_4 42]]}
  [:vbox {} ...]
  [:hbox {} ...]]
```

## Anchor keywords

9 anchors from the 3x3 grid of vertical (top/center/bottom) x horizontal (left/center/right):

| Keyword | Origin point | Growth direction |
|---|---|---|
| `:top_left` | Window top-left corner | Right and down |
| `:top_center` | Window top-center edge | Both horizontal, down |
| `:top_right` | Window top-right corner | Left and down |
| `:center_left` | Window center-left edge | Right, both vertical |
| `:center` | Window center | Both directions |
| `:center_right` | Window center-right edge | Left, both vertical |
| `:bottom_left` | Window bottom-left corner | Right and up |
| `:bottom_center` | Window bottom-center edge | Both horizontal, up |
| `:bottom_right` | Window bottom-right corner | Left and up |

## Resolution math

After resolving w and h from the viewport values (px, `:full`, or fraction), the anchor determines the final rect position:

**Horizontal (x):**
- left: `rect.x = offset_x`
- center: `rect.x = win_w/2 - w/2 + offset_x`
- right: `rect.x = win_w - w + offset_x`

**Vertical (y):**
- top: `rect.y = offset_y`
- center: `rect.y = win_h/2 - h/2 + offset_y`
- bottom: `rect.y = win_h - h + offset_y`

The offset values (x, y) shift from the anchor position. They support the same value types as w/h: pixel numbers, `:full`, and `:M_N` fractions.

## Type changes

New enum in `src/host/types/view_tree.odin`:

```odin
ViewportAnchor :: enum u8 {
    TOP_LEFT,
    TOP_CENTER,
    TOP_RIGHT,
    CENTER_LEFT,
    CENTER,
    CENTER_RIGHT,
    BOTTOM_LEFT,
    BOTTOM_CENTER,
    BOTTOM_RIGHT,
}
```

ViewportRect changes from `[4]ViewportValue` to a struct:

```odin
ViewportRect :: struct {
    anchor: ViewportAnchor,
    x:      ViewportValue,
    y:      ViewportValue,
    w:      ViewportValue,
    h:      ViewportValue,
}
```

## Parsing changes

In `bridge.odin`, the "stack" case reads 5 elements per rect instead of 4. The first element is always a string parsed as an anchor keyword. The remaining 4 are parsed as before (number, "full", or fraction).

Unrecognized anchor strings log an error and default to `TOP_LEFT`.

## Rendering changes

In `render.odin`, `render_children_viewport` resolves w and h first, then applies the anchor math to compute the final x and y.

## Files changed

- `src/host/types/view_tree.odin` — replace ViewportRect array type with struct, add ViewportAnchor enum
- `src/host/bridge/bridge.odin` — parse 5-element rects with anchor keyword
- `src/host/render.odin` — apply anchor math in render_children_viewport
- `test/ui/viewport_app.fnl` — update to new format
- `docs/core-api.md` — document new format
