# treedo — visual reimagining ("dusk forest glade")

**Status:** approved
**Date:** 2026-06-07
**Type:** example app visual rework (no framework changes)
**File:** `examples/treedo.fnl`
**Supersedes (visually):** `2026-05-18-treedo-example-design.md` (behavior unchanged)

## Purpose

The original treedo works but reads as a small tree tucked in a corner
and a flat panel floating in a large dark void. This pass reimagines the
composition into a single cohesive **scene** — a large tree standing as
the hero in a textured forest glade under a twilight sky, with the todo
list as a translucent card resting in that scene.

No behavior changes: add / remove / drag-reorder, the sprout-in and
falling-leaf animations, and all event handlers stay exactly as they are.
This is purely a visual rework of the canvas providers, theme, and layout.

## Approved direction

- **Ambition:** reimagine the composition (not just polish in place).
- **Priorities:** tree as hero · fill the void · color & contrast · panel polish.
- **Composition:** **split scene** — tree as hero on the left/center, card
  on the right, atmospheric backdrop spanning the full window behind both.

## Composition

```
┌──────────── twilight sky · moon · stars ───────────┐
│        ☾                                            │
│              ╱│╲           ┌─────────────────┐      │
│            ╱  │  ╲         │ treedo   (4)     │      │
│           leaves on        │ [ input ][Plant]│      │
│           BIG tree         │ ◖ Plant the seed│      │
│  ~~~~~~~~~~ ground ~~~~~~~  │ ◖ Water sapling │      │
│  moss·mushroom·path·grass  │ ◖ ...           │      │
└──────────── distant treeline ──────────────────────┘
```

Top-level `:stack` with three full-context layers:

1. `:forest-scene` canvas — `:full :full`. Backdrop for the whole window.
2. `:tree-of-life` canvas — `:full :full`. Tree drawn at window-relative
   coordinates so its base meets the same horizon line the backdrop uses
   (shared coordinate space = guaranteed alignment, no fiddly offsets).
3. `:canopy` card — anchored `center_right`, ~440 wide, fixed height,
   translucent + shadowed.

Both canvases are full-window and share a single `horizon = floor(h * 0.64)`
formula plus a `tree-base = (floor(w * 0.36), horizon)` anchor, so the
ground texture and the trunk roots line up at any window size.

## Palette additions

Keep the existing 10 forest tokens; add a twilight-sky set:

| Token            | Value (approx)   | Use                              |
|------------------|------------------|----------------------------------|
| `sky-top`        | `[24 22 46]`     | top of sky gradient (deep night) |
| `sky-mid`        | `[58 46 80]`     | mid sky (dusk purple)            |
| `sky-low`        | `[150 96 92]`    | sky just above horizon (mauve)   |
| `horizon-glow`   | `[228 168 96]`   | warm band at the horizon         |
| `moon`           | `[244 238 214]`  | moon disc                        |
| `moon-halo`      | `[244 238 214 40]`| soft glow ring (alpha)          |
| `star`           | `[210 214 196]`  | stars / twinkle                  |
| `silhouette`     | `[30 30 44]`     | distant treeline (darker than sky-low) |
| `grass`          | `[58 86 50]`     | foreground grass tufts           |

Final integer values tuned against screenshots; table is the intent.

## Canvas providers

### `:forest-scene` (replaces `:forest-floor`)

Full window. Layers, back to front:

1. **Sky gradient** — from `horizon` up to the top, draw horizontal bands
   interpolating `horizon-glow → sky-low → sky-mid → sky-top`. Bands are
   chunky (4–8px) with a light ordered-dither row at each boundary to keep
   the pixel-art feel rather than a smooth blend.
2. **Moon** — a filled disc with 1–2 fainter halo rings, placed high-left
   so it reads behind the tree's canopy gap.
3. **Stars** — deterministic LCG scatter in the *upper* sky only; a few
   gently twinkle (alpha driven by `sin(now + i)`).
4. **Distant treeline** — a row of `silhouette`-colored triangular conifer
   shapes (stacked rects) along the horizon for depth.
5. **Ground** — from `horizon` down: a darker gradient, then denser moss
   flecks, capped mushrooms (stem + colored cap), grass tufts near the
   front, and the central dirt path with sunset-gold stones (now in front
   of nothing — visible).
6. **Fireflies (subtle)** — a handful of `leaf-bright`/`sunset-gold` glowing
   dots drifting via `sin`/`cos(now)`, low over the ground. Tasteful, few.

### `:tree-of-life` (enlarged hero)

Full window; tree drawn relative to `tree-base`.

- **Roots** flaring left/right into the ground at the base.
- **Trunk** taller and a touch wider, lit edge on the right (as today).
- **Branches** — ~6–8 branches alternating left/right up the trunk plus a
  crown, drawn as the existing tapered chunk segments at the new scale.
- **Leaf slots** — generated per branch from inner→tip, then **ordered
  ring-by-ring across branches** (ring 0 = innermost slot of every branch,
  ring 1 = next, …). Filling slots in this order spreads leaves evenly
  across all branches instead of loading one branch first — the core fix
  for today's lopsided clumping. Wrap modulo total slots.
- Sprout-in (`item.born`), falling-leaf, and sway animations carry over,
  re-tuned to the new leaf scale.

### `:vine` and `:vine-grip`

- `:vine` (drag overlay) carries over; re-check halo dimensions against the
  new row height.
- `:vine-grip` restyled into a small **leaf bud** so the drag handle doubles
  as the row's bullet.

## Theme changes

- `:canopy` — add `:opacity ~0.9` and `:shadow [0 8 24 [0 0 0 150]]` so the
  card reads as resting in the scene; keep radius/padding.
- `:heading` — slightly larger; `:count-badge` becomes a pill (`:bg`,
  `:radius`, `:padding`).
- `:trail` / `:trail#hover` — tighter, clearer row affordance.
- Input/`:bark`, `:leaf`, `:mushroom` aspects kept; minor contrast tuning.

## Out of scope

- No framework / Odin / parser changes; no new node types.
- No new state, handlers, subscriptions, or events — behavior identical.
- No image assets — everything from canvas primitives.
- No persistence; no real-time day/night cycle (the sky is a fixed dusk).

## Acceptance

1. `./build/redin examples/treedo.fnl` opens a full twilight-forest scene:
   graded sky, moon, stars, distant treeline, textured ground.
2. The tree is a large hero on the left/center; the card sits on the right;
   no large empty void remains.
3. With the 4 seeded items, leaves are spread across multiple branches
   (not clumped on one).
4. Adding sprouts a new leaf on the next branch in round-robin order;
   removing drops a falling leaf; drag still draws the vine and reorders.
5. The card is visibly translucent + shadowed and reads as part of the scene.
6. Style is still recognizably chunky pixel-art (banded gradient, 4px grid).
