# treedo — forest-themed todo example

**Status:** approved
**Date:** 2026-05-18
**Type:** example app (no framework changes)
**File:** `examples/treedo.fnl`

## Purpose

Ship a second showcase example next to `examples/kitchen-sink.fnl` that
exercises canvas primitives, the `:animate` decoration, and the
drag-and-drop reorder pipeline in service of a single themed
experience. The goal is to demonstrate possibilities of the framework,
not to test framework correctness — no UI test pair is required.

## User-visible behavior

A pixel-art todo app called **treedo**. Users add rows via an input + Add
button, reorder rows by drag-and-drop, and remove rows via a small icon
button. The window shows:

1. A dark forest-floor backdrop with subtle moss and mushroom
   speckling and a faint dirt path.
2. A pixel-art tree pinned bottom-left of the window. Each todo becomes
   a leaf on a specific branch. Adding a todo makes a leaf sprout
   (1px → full size pixel pop). Removing a todo makes that leaf fall
   with gravity and sway, fading out.
3. A 480-wide moss-toned panel pinned top-center with the input, Add
   button, and scrollable list.
4. While a row is being dragged, a green vine grows from one corner of
   the dragged preview around its perimeter over ~0.4s, with tiny leaf
   tufts that sway once the vine is fully extended.

All artwork is drawn from `ctx.rect` / `ctx.circle` primitives snapped
to a 4px grid, so the example is self-contained — no PNG assets.

## Aesthetic

Pixel art means:

- Every visual element is a rect or short line snapped to integer
  coordinates.
- "Big pixels" are 4×4 actual pixels — the smallest visible feature
  size in any canvas. Leaves and trunk segments use multiples of 4px.
- Palette is limited to ten colors (below). No anti-aliased curves.
  Where a curve is needed (vine), it is approximated by short
  axis-aligned rect segments.

Palette (RGB integers):

| Token         | Value           | Use                                  |
|---------------|-----------------|--------------------------------------|
| `night-soil`  | `[22 28 22]`    | background, forest floor             |
| `bark-dark`   | `[54 38 28]`    | tree trunk shadow side               |
| `bark-mid`    | `[96 70 48]`    | tree trunk lit side                  |
| `moss`        | `[70 92 58]`    | row surface, drop-zone armed         |
| `leaf-deep`   | `[54 110 56]`   | vine stems, leaf shadow side         |
| `leaf-mid`    | `[120 170 70]`  | leaf primary color, dragging-row bg  |
| `leaf-bright` | `[200 220 110]` | leaf highlight, primary button bg    |
| `sunset-gold` | `[228 188 90]`  | path stones, count badge text        |
| `mushroom`    | `[180 60 70]`   | remove icon hover, mushroom flecks   |
| `bone-white`  | `[232 224 196]` | heading text, leaf-button text       |

## Theme aspects

Mirrors kitchen-sink's structure but renamed to the forest vocabulary:

| Aspect              | Purpose                                |
|---------------------|----------------------------------------|
| `:canopy`           | Panel surface (`bg [38 46 38]`, padding 20, radius 8) |
| `:heading`          | "treedo" title (size 22, bone-white)   |
| `:body`             | Row text (size 14, bone-white)         |
| `:count-badge`      | "N items" text (size 12, sunset-gold)  |
| `:trail`            | Row default (padding 4, no bg)         |
| `:trail#hover`      | Row hover (bg `moss`)                  |
| `:row-vining`       | Row while dragged (bg `leaf-mid`, color `night-soil`, shadow `[0 4 16 [0 0 0 140]]`) |
| `:row-drop-hot`     | Row that is the drop target (bg `[90 130 60]`) |
| `:muted-armed`      | Scroll container while drag in flight (bg `[48 56 48]`) |
| `:bark`             | Input field (bg `bark-dark`, color `bone-white`, border `bark-mid`) |
| `:bark#focus`       | Focused input (border `leaf-bright`)   |
| `:leaf`             | Primary "Add" button (bg `leaf-bright`, color `night-soil`, weight 1) |
| `:leaf#hover`       | (bg `[215 230 120]`)                   |
| `:leaf#active`      | (bg `[180 200 90]`)                    |
| `:mushroom`         | Remove icon (bg `bark-dark`, color `[160 150 130]`) |
| `:mushroom#hover`   | (color `mushroom`)                     |
| `:mushroom#active`  | (bg `bark-mid`)                        |

## Canvas providers

### `:forest-floor` (background)

Full-window, drawn once per frame. No `redin.now` dependency.

1. Fill `night-soil`.
2. Loop a deterministic pseudo-random sequence (LCG seeded with a
   constant) emitting ~80 mushroom-color dots and ~120 moss-color dots
   of 2px size at integer coords.
3. Draw a vertical "path" band of ~60px width down the middle with a
   slightly darker tint, dotted with sunset-gold "stones" every ~24px.

The provider has no state; same output every frame.

### `:tree-of-life` (the namesake feature)

Drawn into a 240×320 canvas pinned to bottom-left.

**Trunk + branches**: a hardcoded list of rect segments in pixel-space
(each rect is a multiple of 4px) shapes a trunk rising from the bottom
center and four diagonal branches. Drawn in `bark-dark` and `bark-mid`
(lit side = right edge of each rect).

**Leaf slots**: a hardcoded list of 32 `[x y]` integer coordinates on
or near branch tips. Slots are visited in array order.

**Leaf rendering**: for each item index `i` in `(subscribe :items)`,
draw a leaf at slot `i` (modulo 32 — beyond 32 todos the tree wraps
back over itself, which is acceptable for a demo).

- Leaf shape: a 12×8 pixel-art cluster of rects (three colors:
  `leaf-deep` outline, `leaf-mid` body, `leaf-bright` highlight),
  rotated by index parity (slot `i` even = lean right; odd = lean
  left).
- Leaf color tint cycles `i mod 3` across leaf-deep / leaf-mid /
  leaf-bright as the body color, keeping outline + highlight constant.
- Sway: leaf draws at `(x + round(sin(now * 1.3 + i) * 1), y)`. Cheap
  bob, no per-leaf state.

**Sprout-in (add)**: when an item was added within the last 0.3s, the
leaf scales from 1px → 2 → 3 → 4 big-pixel widths, four discrete steps.
Detection: the `:items` shape becomes `[{:text "...", :born now} ...]`
so each item carries its spawn timestamp. The canvas reads `item.born`
and computes `growth = clamp((now - born) / 0.3, 0, 1)`. Leaves whose
growth has reached 1 are drawn full-size.

**Falling-leaves (remove)**: separate state slice
`db.falling-leaves = [{:slot N :spawn t}, ...]`. On remove, the
`:test/remove` handler pushes one entry with the slot index of the
removed item and the current `redin.now`. The slot's `[x y]` and color
are looked up by the canvas at draw time from the same hardcoded slot
table the live leaves use, so the falling-leaf state stays small.

In the provider, for each falling leaf:

```
[sx, sy] = slot-table[entry.slot]
body-color = leaf-colors[entry.slot mod 3]
age = now - entry.spawn          ; seconds
t   = age / 1.6
draw_x = sx + sin(age * 4) * 8
draw_y = sy + (250 * t * t)             ; quadratic-ish fall
alpha  = max(0, 1 - t)
draw leaf at (draw_x, draw_y) with body color, alpha applied
```

Entries with `t >= 1` are no longer drawn. A `:tick/clear-fallen`
handler prunes entries with `age > 2` and re-arms itself via
`dispatch-later 2000ms`. The tick is bootstrapped by a top-level
`(dispatch [:tick/clear-fallen])` call at the end of the Fennel
module (same pattern other examples use for one-shot startup work).

### `:vine` (drag overlay)

Used as an `:animate` decoration inside the `:draggable` attribute of
each row. The framework already gates animate-on-draggable to the
dragged preview, so the vine only appears while a row is mid-drag.

Rect: `[:top_left -6 -6 :full :full]` — extends 6px out from the row.

**Drawing**: the provider treats the row's perimeter as a closed loop
(top → right → bottom → left → top) of total length `P = 2*(w + h)`.
It needs the canvas's pixel size (`ctx.width`, `ctx.height`) which the
host already provides.

Vine progress: `growth = clamp((now - drag-start-time) * 2.5, 0, 1)`.
Drawn length: `L = P * growth`.

Walk the perimeter in 4px steps. For each step where cumulative
distance ≤ L:

- Draw a 3×3px `leaf-deep` segment at the perimeter point.
- Every 6th step, draw a 5×5 leaf tuft (a small pixel cluster) in
  `leaf-mid` with a 1px `leaf-bright` highlight.

Once `growth == 1`, each leaf tuft applies a `sin(now * 2 + tuft-idx)`
±1px vertical bob.

The provider reads `db.drag-start-time` via subscription. If `nil`,
the provider draws nothing (defensive — should not happen because
the host already gates `:animate` on draggable to the active drag).

## State shape

```fennel
{:items [{:text "Plant the seed" :born 0}
         ...]
 :input-value ""
 :drag-start-time nil           ;; number (redin.now) when a drag is active
 :falling-leaves []}            ;; transient
```

`:born` defaults to `(redin.now)` at app init for seeded items so they
do not all sprout-in at boot. New items get the actual current time.

## Handlers

| Event              | Behavior |
|--------------------|----------|
| `:tick/clear-fallen` | Prunes `falling-leaves` where `now - spawn > 2`. Re-arms via `dispatch-later 2000ms`. Bootstrapped by a top-level `(dispatch [:tick/clear-fallen])` at module load. |
| `:test/input`      | Mirrors kitchen-sink: stores `input-value`. |
| `:test/add`        | Appends `{:text V :born (redin.now)}` if value nonempty; clears input. |
| `:test/remove i`   | Removes item `i`; pushes falling-leaf entry with that slot's color + current time. |
| `:event/drag`      | Sets `drag-start-time` to `(redin.now)`. |
| `:event/over`      | No-op (event exists so the drag-over aspect applies). |
| `:event/drop`      | Reorders items (same logic as kitchen-sink), clears `drag-start-time`. |

## View structure

Top-level `:stack` with viewport:

1. `[:canvas {:provider :forest-floor :width :full :height :full}]` filling the window.
2. `[:canvas {:provider :tree-of-life :width 240 :height 320}]` pinned bottom-left at offset `[16 -16]`.
3. `[:vbox {:aspect :canopy}]` pinned top-center, 480px wide:
   - Header hbox: `[:text :heading "treedo"]` + spacer + `[:text :count-badge "N items"]`
   - 16px gap
   - Input + Add button hbox (input fills, button 72px wide)
   - 12px gap
   - Scrollable vbox `:overflow :scroll-y` with `:drag-over`, containing one row per item:
     - Grip vbox (24px wide, `:drag-handle true`, drawn with a small
       `:vine-grip` 3-dot canvas to match the theme).
     - Item text (`:body`, `:width :full`).
     - Remove button (`:mushroom`, 32×32, "x").

Each row's `:draggable` carries:

```fennel
:draggable [:row-drag {:mode :preview
                       :handle false
                       :event :event/drag
                       :aspect :row-vining
                       :animate {:provider :vine
                                 :rect [:top_left -6 -6 :full :full]
                                 :z :above}}
            i]
```

And `:dropable [:row-drag {:event :event/drop :aspect :row-drop-hot} i]`.

## Out of scope

- No new node types, no parser changes, no framework Odin edits.
- No UI test file (matches kitchen-sink convention).
- No PNG / image assets.
- No real-time clock features (day/night cycle, fireflies, etc.).
- No persistence — state is in-memory only, matching kitchen-sink.

## Acceptance

1. `./build/redin examples/treedo.fnl` opens the app with seeded
   items.
2. Adding a todo causes a new leaf to sprout-in on the tree.
3. Removing a todo causes a leaf to fall and fade out.
4. Starting a drag draws a vine that visibly extends around the
   dragged row's perimeter over ~0.4s.
5. Dropping reorders items (same as kitchen-sink), and the vine
   disappears as the preview goes away.
6. Visual style is recognizably pixel-art (no soft curves, 4px
   feature grid, limited palette).
