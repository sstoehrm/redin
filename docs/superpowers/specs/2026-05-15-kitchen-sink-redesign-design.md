# Kitchen-sink redesign

Refresh the `examples/kitchen-sink.fnl` demo so it works as a showcase for the
framework instead of looking like a maintenance scratchpad. Fix one drop-handler
off-by-one along the way.

Scope: a single file. No framework, theme schema, or canvas API changes.

## Motivation

The current kitchen-sink has three real problems:

1. **Layout bugs read as "broken framework".** `:width 250` on the `Add`
   button and `remove` buttons stretches edge-to-edge because the parent
   `vbox` does not constrain — the literal width attribute looks ignored even
   though it is not. Bad first impression in screenshots / demos.
2. **Visual hierarchy is flat.** The surface card at `0.5` opacity dissolves
   into the background; the bright magenta `[136 46 106]` dragging color
   clashes with the Nord palette; the drag handle is a 24×42 dark-gray block
   that reads as decoration rather than a grip.
3. **Drop reorder is off-by-one in one direction.** Dragging a row downward
   lands it one slot above the target.

Fixing these makes the demo do its job (sell the framework) without expanding
its scope.

## Non-goals

- No new framework features. Canvas API, theme schema, drag-and-drop event
  shape — all untouched.
- No new test file. `test/ui/test_drag.bb` exercises the drag mechanics on a
  separate app (`drag_app.fnl`) and stays untouched.
- No light theme. The dark Nord identity is part of redin's look; we refine,
  not replace.
- No new UI test for kitchen-sink (it is a demo, not a test surface).

## Design

### Layout

A centered card with a fixed max width, surrounded by the background canvas.

```
┌─────────────── window ────────────────┐
│           [background canvas]          │
│                                        │
│      ╭───────── 480px ──────────╮      │
│      │  Todo List           24  │  ← header: title + count
│      │  ────────────────────────│
│      │  ┌────────────┐ ┌──────┐ │  ← input + Add side by side
│      │  │ new todo…  │ │  Add │ │
│      │  └────────────┘ └──────┘ │
│      │                          │
│      │  ⋮⋮  Test 1          ×  │  ← grip · text · remove
│      │  ⋮⋮  Test 2          ×  │
│      │  …  (scrolls)            │
│      ╰──────────────────────────╯
│                                        │
└────────────────────────────────────────┘
```

- Card centered via `stack`'s `:viewport`. The stack now has two children
  (background canvas + card), so `:viewport` is a 2-entry vector:
  `[[:top_left 0 0 :full :full] [:center 0 32 480 :full-64]]` — full-size
  background, card anchored center with 480 width and 32px top/bottom inset.
  Exact anchor token (`:center` vs `:top_center` with explicit y) confirmed
  during implementation against `docs/core-api.md § Viewport`.
- Card padding: `[20 20 20 20]`.
- Header → input gap: 16px. Input row → list gap: 12px.
- Row height: 42px (unchanged).
- Grip column: 24px fixed. Text fills. Remove becomes a 32×32 `button`
  with `"×"` as its label (no icon system in redin) and a `:button#hover`
  variant that swaps text color to `danger`.
- The current bottom-center status strip is removed; the count moves into the
  header.

### Palette

Token map (kept in the existing `set-theme` call):

| Token | Value | Use |
|---|---|---|
| `bg` (window) | `[30 34 46]` | Polar night base (unchanged). |
| `surface` | `[46 52 64]` opacity `1.0` | Card fill (was `0.5` — ghosting). |
| `surface-elev` | `[59 66 82]` | Header strip, row hover, drop-hot bg. |
| `text` | `[236 239 244]` | Heading. |
| `body` | `[216 222 233]` | Item text. |
| `muted` | `[129 138 155]` | Count badge, grip default, placeholder. |
| `accent` | `[136 192 208]` | Add button bg, focused input border, drop-hot left border, grip hover. |
| `danger` | `[191 97 106]` | Remove `×` on hover only. |
| `drag-active` | `[94 129 172]` | Dragging row bg (replaces magenta). |

Typography:

- Heading 22pt, weight 1.
- Count badge 12pt, `muted`, right-aligned in header row.
- Body 14pt, `body`.
- Button label 13pt; weight 1 on primary (`Add`), weight 0 on secondary.
- Input value 14pt, 12px horizontal padding.

Primary fill (`accent`) is used **only** on the `Add` button. Everywhere else
the accent is a hairline (focused input border, drop-hot left border, grip
hover). This keeps it special.

### Drag-and-drop visuals

**Grip handle.** New canvas provider `:grip-dots` draws six dots in a 2×3
pattern centered in its rect:

```fennel
(canvas.register :grip-dots
  (fn [ctx]
    (let [cx (/ ctx.width 2)
          cy (/ ctx.height 2)
          gap 5
          r  1.5
          color (or ctx.color [129 138 155])]
      (for [row -1 1]
        (for [col 0 1]
          (ctx.circle (+ cx (* (- (* 2 col) 1) (* gap 0.5)))
                      (+ cy (* row (+ gap (* 2 r))))
                      r {:fill color}))))))
```

The grip `vbox` keeps `:drag-handle true` and renders a `[:canvas {:provider
:grip-dots}]` child filling its 24×42 box.

Hover affordance: a `:drag-handle#hover` aspect lightens the visible fill.
Two implementation routes exist; pick at implementation time:

1. Pass `color` to the canvas via attrs and theme it.
2. Register a sibling `:grip-dots-hot` provider and switch via `:aspect#hover`.

Either is one or two lines. Option 1 is cleaner if the canvas API forwards
attrs to `ctx` (verify against `docs/core-api.md § Animation`); option 2 is
the unconditional fallback.

**Drop-hot indicator.** Replace the bg flash with a 2-px accent left border:

```fennel
:row-drop-hot {:bg [59 66 82]
               :border [136 192 208]
               :border_width 2
               :radius 4
               :padding [4 4 4 4]}
```

Theme borders apply to all sides; on a 42-px row the side/bottom strokes are
subtle and the eye still lands on the left edge. If it reads as too heavy
during implementation, drop to `:border_width 1`.

**Drag preview.** Already uses `:mode :preview`. Update its aspect to a
palette-matching fill plus a drop shadow:

```fennel
:row-dragging {:bg [94 129 172]
               :color [30 34 46]
               :padding [4 4 4 4]
               :radius 4
               :shadow {:x 0 :y 4 :blur 16 :color [0 0 0 120]}}
```

`shadow` is documented in `docs/reference/theme.md` as a theme struct. Confirm
during implementation that it applies to `hbox` rows (not only buttons); if
hbox-shadow is unsupported, drop the `:shadow` key — the color change alone
is enough to differentiate.

### Background canvas

Quiet the current 12-orb soup down to 3 large slow orbs plus a vignette:

- 3 orbs (was 8 + 4). Radius 180–260 px, speed ~0.08 (current ~0.15–0.6),
  alpha 14 (current 18 + 10). Fill `[94 129 172]` — same as `drag-active`,
  ties the screen together.
- Vignette: single overlay pass at the end of the canvas — concentric rect
  strokes from the edges inward, alpha tapering from 0 to ~30 at the corners.
  Crude radial darkening using only `ctx.rect`. Treat as cosmetic: if the
  result looks blocky during implementation (visible stepping), drop the
  vignette — 3 quiet orbs alone is acceptable.
- Drop the second "accent orbs" loop entirely.

Aurora-band alternative was considered and rejected: the canvas API has
`rect` + `circle` only, no native gradient. Faked gradient is more code than
3 orbs for the same end effect.

### Drop-handler fix

Current logic at `examples/kitchen-sink.fnl:170-176`:

```fennel
(let [insert-at (if (> from-idx to-idx) to-idx (- to-idx 1))]
  (table.insert new-items
                (math.min insert-at (+ (length new-items) 1))
                item))
```

After `icollect` removes the source, the index shift is already absorbed.
The conditional re-applies the shift, so dragging downward lands one slot
short.

Trace `[A,B,C,D,E,F,G]` with `from=1, to=5`:

- `new-items` after removing A = `[B,C,D,E,F,G]` (length 6).
- `from < to` → `insert-at = 4`.
- result: `[B,C,D,A,E,F,G]` — A at slot 4, expected slot 5.

Fix — drop the conditional, insert at `to-idx`:

```fennel
(let [item (. items from-idx)
      new-items (icollect [i v (ipairs items)]
                  (when (not= i from-idx) v))]
  (table.insert new-items to-idx item)
  (assoc db :items new-items))
```

Verified by tracing:

| from | to | input | `new-items` | insert | result |
|---|---|---|---|---|---|
| 1 | 5 | `[A,B,C,D,E,F,G]` | `[B,C,D,E,F,G]` | A @ 5 | `[B,C,D,E,A,F,G]` |
| 5 | 1 | `[A,B,C,D,E,F,G]` | `[A,B,C,D,F,G]` | E @ 1 | `[E,A,B,C,D,F,G]` |
| 1 | 2 | `[A,B,C,D]` | `[B,C,D]` | A @ 2 | `[B,A,C,D]` |
| 2 | 1 | `[A,B,C,D]` | `[A,C,D]` | B @ 1 | `[B,A,C,D]` |
| 1 | 7 | `[A,B,C,D,E,F,G]` | `[B,C,D,E,F,G]` | A @ 7 | `[B,C,D,E,F,G,A]` |

Guard against out-of-range `to-idx` (defensive — the framework only emits
indices that exist, but the handler already does range validation):

```fennel
(when (and from-idx to-idx
           (> from-idx 0) (<= from-idx (length items))
           (> to-idx   0) (<= to-idx   (length items))
           (not= from-idx to-idx))
  …)
```

This existing guard is kept verbatim; the body inside it is what changes.

## Affected files

- `examples/kitchen-sink.fnl` — only file modified.

## Verification plan

- **Visual diff.** Existing `/tmp/redin-shots/kitchen-before.png` is the
  baseline. After landing changes, capture `kitchen-after.png` via the dev
  server `/screenshot` endpoint. Side-by-side eyeball check — no automated
  pixel diff (would over-trigger).
- **Manual drag sanity.** Two paths:
  1. POST `/events` with `["event/drop" {:from N :to M}]` for a few
     `(N, M)` pairs from the trace table; assert state via `/state/items`.
  2. Real mouse via `/input/takeover` + `/input/mouse/{move,down,up}`:
     drag row 1 onto row 5, confirm new ordering matches the table.
- **Release build.** `odin build src/cmd/redin
  -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
  must succeed unchanged.
- **Existing tests.** `bb test/ui/test_drag.bb` (and other UI tests) must
  remain green. Kitchen-sink isn't part of `run-all.sh`, so no regression
  vector there.

## Implementation notes (carry into the plan)

- All work is in one file; do not split.
- The `canvas` provider for `:grip-dots` registers at top level alongside
  `:background` and `:pulse-dot`.
- The hover-color route for the grip is decided at implementation time after
  a 30-second check of how `canvas` attrs flow to `ctx`.
- The `shadow` aspect key on `:row-dragging` is conditional on hbox-shadow
  support; remove if it errors at render.
