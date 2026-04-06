# Canvas Provider Reference

Custom render regions driven by Lua/Fennel callbacks registered against a provider name.

> **Status:** The canvas provider concept exists in the host types (`NodeCanvas` in `src/host/types/view_tree.odin`) and is parsed by the view tree parser, but host-side rendering is placeholder only. The API below documents the planned design.

---

## Registration

```fennel
(register "my-canvas"
  {:start  (fn [ctx] ...)   ;; canvas becomes visible
   :update (fn [ctx] ...)   ;; called every frame while visible
   :halt   (fn [ctx] ...)   ;; canvas leaves the visible tree
   :stop   (fn [ctx] ...)}) ;; canvas removed from tree permanently
```

`register` is available as a global and as `redin.register`. The first argument is the provider name string; it must match the `provider` attribute on the canvas element. The second argument is a table with lifecycle callbacks -- all four keys are required.

---

## Canvas element

```fennel
[:canvas {:id :my-canvas :provider :my-canvas :width 400 :height 300}]
```

The `provider` attribute links the element to its registered provider. `width` and `height` set the render texture size in pixels.

---

## Lifecycle

| Callback | When called |
|----------|-------------|
| `start` | Once when the canvas first appears in the frame tree (or re-appears after removal). Use to initialize local state. |
| `update` | Every frame while the canvas is visible. This is where drawing happens. |
| `halt` | When the canvas leaves the visible frame tree but may return. Provider state is preserved. |
| `stop` | When the canvas is permanently removed from the tree. Clean up resources here. |

---

## Context table

Every callback receives a `ctx` table. `update` uses it most -- the drawing primitives are all here.

| Key | Type | Description |
|-----|------|-------------|
| `state` | table | Provider-local state, persists across frames |
| `width` | number | Canvas width in pixels |
| `height` | number | Canvas height in pixels |
| `clear` | function | `clear(r, g, b, a)` -- fill the canvas with a color |
| `line` | function | `line(x1, y1, x2, y2, color)` -- draw a line segment |
| `line_strip` | function | `line_strip(points, color)` -- draw connected line segments |
| `rect` | function | `rect(x, y, w, h, color)` -- draw a filled rectangle |
| `circle` | function | `circle(cx, cy, radius, color)` -- draw a filled circle |
| `text` | function | `text(str, x, y, font_size, color)` -- draw text |
| `poll_events` | function | `poll_events()` -- return input events within canvas bounds |

**Colors** are `[r, g, b, a]` tables with values 0--255.

**Points** for `line_strip` are `[[x1, y1], [x2, y2], ...]`.

---

## Example: animated dot-grid background

```fennel
(var time 0)

(register "dot-grid"
  {:start  (fn [ctx] nil)
   :update (fn [ctx]
     (set time (+ time 0.016))
     (let [{: width : height : clear : circle} ctx
           spacing 40
           cols (math.ceil (/ width spacing))
           rows (math.ceil (/ height spacing))]
       (clear 46 52 64 255)
       (for [r 0 rows]
         (for [c 0 cols]
           (let [x (* c spacing)
                 y (* r spacing)
                 pulse (+ 0.3 (* 0.2 (math.sin (+ time (* 0.1 (+ r c))))))
                 alpha (math.floor (* pulse 255))]
             (circle x y 2 [180 190 200 alpha]))))))
   :halt   (fn [ctx] nil)
   :stop   (fn [ctx] nil)})
```

Use in a frame:

```fennel
[:canvas {:id :bg :provider :dot-grid :width 800 :height 600}]
```

---

## Notes

- Provider names are global -- two registrations with the same name, the second wins.
- `state` in `ctx` is the same table across every call. Mutate it directly to persist values between frames.
- Drawing calls outside `update` are ignored.
- The canvas element is a leaf: the validator rejects child frames inside it.
