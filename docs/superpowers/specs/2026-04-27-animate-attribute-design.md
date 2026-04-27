# Animate Attribute — Design

**Date:** 2026-04-27
**Status:** Approved, ready for implementation planning

## Goal

Let any element host a small canvas-rendered ornament — a blinking notification star at a button's corner, a subtle pulse behind a tile, a shimmer next to a label. The decoration is positioned relative to the host using the existing viewport-rect syntax, animated by the same canvas providers that already exist, and renders without entering the hit-test path.

Non-goals: a keyframe / tween primitive in the framework itself; theme-driven animation; multiple decorations per host; interactive decorations (decoration owns a `:click`). Each is reachable later by extension; none is needed for the first cut.

## Motivation

redin has no animation infrastructure today. The only motion in the framework is the hardcoded text-cursor blink in `src/redin/render.odin`. Apps that want a blinking star at a button corner currently have to either nest the button in a `:stack` with a sibling `:canvas`, or build a custom node type. Both work but are heavier than the visual deserves.

Canvas providers already give us per-frame `update(rect)` callbacks with `now()` access — every animation primitive an app would want already lives in user-controlled provider code. The missing piece is *positioning*: a way to anchor a small canvas at a corner of a host element without restructuring the surrounding view.

## API

A new `:animate` attribute available on every node type. The attribute value is a map:

```fennel
[:button {:animate {:provider :star-blink
                    :rect [:top_left -4 -4 16 16]
                    :z :above}}
  "Click me"]
```

Fields:

| Field | Required | Type | Notes |
|---|---|---|---|
| `:provider` | yes | keyword or string | Name of a registered canvas provider. Same registry as `:canvas` — no separate "animation" registry. |
| `:rect` | yes | 5-element vector | `[anchor x y w h]`, identical to the `:viewport` spec on `:stack`. |
| `:z` | no | `:above` (default) or `:behind` | Draw order relative to the host element. |

`:rect` reuses the viewport solver verbatim. Anchors are the existing 9-value enum (`:top_left`, `:top_center`, …, `:bottom_right`). `x`/`y` are pixel offsets from the anchor; negative is allowed so `[:top_left -4 -4 16 16]` lets a 16×16 ornament overhang the corner. `w`/`h` accept pixel numbers, `:full` (resolves to the host's width or height), or `:M_N` fractions.

### Examples

```fennel
;; Blinking star at the top-left corner, overhanging by 4 px.
[:button {:click [:dismiss]
          :animate {:provider :star-blink
                    :rect [:top_left -4 -4 16 16]}}
  "Dismiss"]

;; Subtle glow behind a tile, sized to the host.
[:vbox {:aspect :tile
        :animate {:provider :soft-glow
                  :rect [:center 0 0 :full :full]
                  :z :behind}}
  ...]

;; Notification badge centered on the bottom-right corner.
[:hbox {:animate {:provider :unread-badge
                  :rect [:bottom_right -8 -8 16 16]}}
  [:image {:src "avatar.png"}]]
```

The provider receives the resolved rect every frame and draws into it using the existing canvas API (`ctx.rect`, `ctx.circle`, …). Mouse-input queries (`ctx.mouse-in?`, `ctx.mouse-x`, `ctx.mouse-pressed?`) work in canvas-local coordinates as they do for regular `:canvas` elements, so a provider can react visually to hover or press. There is no event dispatch from the decoration in v1.

## Behaviour

### Render order

- `:above` — drawn after the host element finishes drawing (host's own visual contribution + the entire descendant subtree). The decoration sits on top of everything inside the host.
- `:behind` — drawn just before the host element starts drawing. Anything the host paints (background, border, children) is layered on top.

### Click-through

The decoration's rect never enters the hit-test arrays (`node_rects`). Mouse clicks land on whatever the host normally responds to. If the user wants a clickable ornament they nest a button manually; this attribute is purely visual.

### Per-frame redraws

The renderer already runs every frame, and canvas providers' `update` already runs every frame. Time-driven animation lives in the provider via `now()`. No new dirty-tracking or invalidation work.

### Errors

| Condition | Outcome |
|---|---|
| `:provider` references an unregistered name | `canvas.process` returns silently — no draw, no crash, same posture as a `:canvas` element pointing at an unregistered name. |
| `:rect` is malformed (wrong arity, unknown anchor token, non-numeric coordinate) | Log a warning at parse time and discard the entry — `node_animations[idx]` stays nil, so the renderer never tries to draw it. The host element renders normally. The warning fires once per re-flatten the malformed value is seen, not once per frame. |

## Implementation outline

### Types

New struct in `src/redin/types/view_tree.odin`:

```odin
Animate_Z :: enum u8 { Above, Behind }

Animate_Decoration :: struct {
    provider: string,             // owned, freed on clear_frame
    rect:     ViewportRect,        // existing struct from viewport feature
    z:        Animate_Z,
}
```

`ViewportRect` is the existing 5-field struct (`anchor`, `x`, `y`, `w`, `h`) added in the viewport-anchor-points feature. Reusing it directly means the parser, solver, and validation all carry over unchanged.

### Storage

A new parallel side table aligned with the node array:

```odin
node_animations: [dynamic]Maybe(Animate_Decoration)
```

Same length as `nodes`. O(1) lookup by node idx, sparse (most entries are `nil`). Indexed by the same idx as `node_rects`, `parent_indices`, etc. `clear_frame` in `bridge.odin` empties this table on every re-flatten alongside the other idx-keyed side tables.

### Parsing

In `src/redin/bridge/bridge.odin`, the existing per-node attribute parser gains an `:animate` case:

1. If the attribute is missing, leave `node_animations[idx]` as nil.
2. If present, expect a Lua table with `provider`, `rect`, optional `z`.
3. Reuse the viewport rect parser (already invoked by `:stack {:viewport ...}`) for the 5-element vector.
4. `z`: if absent or `:above` → `.Above`. If `:behind` → `.Behind`. Anything else → warn + treat as `.Above`.
5. `provider`: clone the string into the animations side table.
6. On any required-field failure, warn and skip storing — the host element still renders normally.

### Rendering

In `src/redin/render.odin`, the draw walk gains two new hooks per node:

1. **Before the host's own drawing**: if `node_animations[idx]` is `:behind`, resolve its rect against the host's `node_rects[idx]` using the existing viewport solver, then dispatch to the canvas provider via the existing `lua_canvas_draw` path.
2. **After the host's subtree completes**: if `:above`, same dispatch.

For the first cut, implement `:above` as a second pass over `node_animations` after the main render walk, drawing every `:above` decoration in node-array order. This is structurally simple and correct for every layout the feature is motivated by (corner ornaments on flow-laid-out elements). The strictly correct subtree-aware variant — fire each decoration the moment its host's last descendant is drawn — only matters when later-drawn unrelated nodes overlap the host's region (overlapping stacks, modals). If a use case appears, upgrade by maintaining a `last_descendant_idx` parallel array computed during flatten and triggering decorations at boundary crossings.

### Hit testing

No change. Decorations don't enter `node_rects`.

### Integration with existing canvas

There is no separate "animation provider" registry. The same `canvas.register("name", proc(...))` registers a provider that can be referenced by `:canvas {:provider :name}` *or* `:animate {:provider :name ...}`. Providers don't know which use case is rendering them; they just get a rect and draw.

## Files changed

- `src/redin/types/view_tree.odin` — `Animate_Decoration` struct, `Animate_Z` enum.
- `src/redin/bridge/bridge.odin` — `:animate` attribute parser; `clear_frame` clears the new side table.
- `src/redin/render.odin` — `:behind` and `:above` draw hooks; reuse of viewport solver for decoration rects.
- `test/ui/animate_app.fnl` — new test fixture: a button with a known-blinking provider, plus a sibling without `:animate` for the negative path.
- `test/ui/test_animate.bb` — bb integration test asserting (a) the host's own behaviour is unchanged, (b) clicks fall through to the host, (c) the decoration provider's `update` runs at frame rate (verifiable via a counter the provider increments).
- `docs/core-api.md` — new "Animation" subsection under attributes; cross-link from the dev-server examples.
- `docs/reference/elements.md` — note `:animate` as a universal attribute.

## Testing

Unit-testable pieces:
- Animate-attribute parser: 6–8 cases (happy path, missing required, unknown anchor, malformed `:z`, malformed rect arity, unregistered provider).
- Side-table invalidation on re-flatten: assert `node_animations` has the right length and content after a Fennel push.

UI-testable pieces (`test/ui/test_animate.bb`):
- A `:button` with a counter-bumping provider, run for N frames, assert the provider counter increased by N (proves frame-rate dispatch).
- The same button with a `:click` listener — bb test posts `/click` at the host's centre, asserts the click event fires (proves click-through).
- Toggle `:z :above` ↔ `:z :behind` between frames, take screenshots, diff selected pixels at the corner to confirm draw order. (Optional; the audit's verification matrix doesn't currently include screenshot diffing.)

## Open questions / future work

- **Multiple decorations per host.** The first design pass considered a list of maps (`:animate [{...} {...}]`); the user opted for a single map for v1. If a use case emerges (star + dot on the same button), upgrade the parser to accept either a single map or a list, with the single-map form syntactic sugar for a one-element list.
- **Interactive decorations.** A decoration that owns its own `:click` listener would need its rect to enter the hit-test arrays. Reasonable extension once a use case appears; held until then.
- **Theme-driven animation.** A theme aspect declaring an animation would let "all buttons get a hover pulse" without per-element wiring. Larger surface (theme system needs time semantics, plus a way to express "default decoration"). Out of scope; revisit after the per-element form has shipped and proven itself.

## Rollout

One PR. Touches three framework files (types, bridge, render) plus tests and docs. The change is additive — existing apps without `:animate` see no behavioural difference. No release-note breakage; the new attribute is optional everywhere.
