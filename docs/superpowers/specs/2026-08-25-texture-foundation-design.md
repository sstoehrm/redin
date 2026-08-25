# Texture foundation — ctx.pixels, canvas image op, [:image] element

**Date:** 2026-08-25
**Status:** Approved design
**Issue:** #279 (canvas command buffer collapses under sprite-heavy scenes)
**Spec figure:** `.blend/specs/2026-08-25-texture-foundation.edn` (serve with `simpleviz`)

## Purpose

redin v0.7.0 cannot display a bitmap anywhere: the frame tree's
`[:image]` element is a themed-rect placeholder, and the canvas
`"image"` op draws a gray stub. Pixel-art apps (drapi) work around
this by drawing sprites as run-length `ctx.rect` calls, which
collapses at scale — ~48k rect commands/frame, 23ms render for a
58-thumbnail filmstrip (#279).

This design adds one texture-loading foundation with three consumers:

1. **`ctx.pixels`** — a canvas primitive that draws an RGBA pixel
   buffer as one texture blit. The direct #279 fix: one command per
   sprite instead of hundreds of rects.
2. **Canvas `image` op** — first real implementation of the reserved
   stub: draws a file-loaded texture.
3. **`[:image]` element** — un-stubbed via a new `:src` attribute;
   the existing (currently unused) `ImageHandlingType` enum becomes a
   `:fit` attribute.

**Non-goals:** intrinsic image sizing in layout (the element keeps
its explicit `width`/`height` behavior; follow-up), palette-indexed
pixel formats, animated textures, network image sources.

## Texture store

New Odin package `src/redin/texture/` owning all `rl.Texture2D`
lifecycle. Two caches:

**Pixels cache** — keyed by content hash: FNV-1a 64 over the RGBA
bytes with `w` and `h` folded in. Hit → return the cached texture;
miss → build an `rl.Image` from the raw bytes, `LoadTextureFromImage`,
set `POINT` filter (crisp nearest-neighbor for pixel art). Content
addressing makes stale textures impossible and needs no invalidation
API; hashing a 64×96 sprite (~24KB) is microseconds.

**File cache** — keyed by path as given (app-relative paths resolve
against the process working directory, same as every other file access
in the runtime). Load failure is cached as a negative entry so a
missing file does not retry every frame; one warning is printed on
first failure. Hot reload clears the file cache (an edited PNG shows
up after reload). The pixels cache is untouched by reload —
content-addressed entries are correct by construction.

**Eviction** — every entry carries a last-used frame stamp, touched on
each use. A once-per-frame sweep (called from the render loop) unloads
entries unused for 120 frames. A total-bytes backstop (64 MB of
texture data) evicts least-recently-used entries beyond the cap even
if recently stamped entries would survive the age check.

**Testability** — cache bookkeeping (hashing, stamps, LRU, byte
accounting) is separated from GPU upload behind a small interface, so
the bookkeeping is unit-testable headlessly in the existing
`*_test.odin` style; only the thin upload/draw shims require a window.

## Canvas primitives

### `ctx.pixels` (runtime side, `src/runtime/canvas.fnl`)

```fennel
(ctx.pixels x y w h data ?opts)   ; data: RGBA byte string, length w*h*4
```

Appends `[:pixels x y w h data opts]` to the command buffer — one
freshly allocated table per *sprite*, not per pixel run. `?opts`:

| Key | Meaning | Default |
|-----|---------|---------|
| `:scale` | integer/float upscale factor (nearest-neighbor) | 1 |

Intended usage pattern (drapi): decode each sprite **once** into an
RGBA string, cache the string in app state, then issue one
`ctx.pixels` call per visible sprite per frame. The 58-thumbnail
scene drops from ~48.5k commands to 58.

### Bridge decode (`execute_canvas_command`, new `"pixels"` arm)

Validation, matching the existing sanitize posture (skip the command
on any violation; no partial draws):

- `data` must be a Lua string; length read NUL-safely via
  `lua_tolstring` (the #277 posture), and must equal `w*h*4` exactly.
- `w`, `h`: positive integers, each ≤ 2048, product ≤ 4,194,304
  (4M pixels — a 16 MB texture ceiling per command).
- `x`, `y` sanitized via `canvas_coord`; `:scale` sanitized to
  `(0, 64]`, default 1 on absence or non-number.

Draw: texture from the store by content hash, then `DrawTextureEx` at
`(ox+x, oy+y)` with the command's scale, under the already-active
canvas scissor.

### `image` op (un-stub)

```fennel
(ctx.image x y w h path ?opts)   ; existing signature; path replaces the TBD name
```

Draws the file texture stretched to `w×h` via `DrawTexturePro`.
Missing/failed texture keeps the current gray placeholder box.

## `[:image]` element

- `types.NodeImage` gains `src: string` and `fit: ImageHandlingType`.
- Attribute reads in both ingestion paths: bridge node conversion
  (`bridge.odin`, `case "image"`) and the static-frame parser
  (`parser/view_tree_parser.odin`). `:fit` accepts `stretch`,
  `stretch-x`, `stretch-y`, `keep`; unknown values fall back to the
  enum default `keep`.
- `render.odin` NodeImage arm: themed chrome (aspect bg/border) as
  today, then the texture drawn per fit mode inside the rect:
  - `stretch` — fill the rect exactly.
  - `stretch-x` / `stretch-y` — fill that axis, preserve aspect ratio
    on the other, centered.
  - `keep` — 1:1 texture pixels, centered, clipped to the rect via
    scissor.
- No `:src`, or load failure → current placeholder rendering.

## Error handling summary

| Failure | Behavior |
|---------|----------|
| `ctx.pixels` data length ≠ `w*h*4`, bad dims, non-string data | command skipped |
| oversized dims (>2048 side or >4M pixels) | command skipped |
| `ctx.image` / `[:image]` file missing or undecodable | negative-cached, warn once, placeholder drawn |
| texture cache over byte cap | LRU eviction, oldest first |
| hot reload | file cache cleared; pixels cache kept |

## Testing

- **Odin unit tests:** texture-store bookkeeping (hash stability,
  hit/miss, frame-stamp eviction, byte-cap eviction, negative
  entries); pixels-command validation alongside
  `canvas_sanitize_test.odin` (length mismatch, dim caps, scale
  clamp, non-string data).
- **UI tests** (per the UI test convention):
  - `test/ui/pixels_app.fnl` + `test_pixels.bb` — canvas provider
    drawing known sprites via `ctx.pixels`; `/screenshot` pixel
    spot-checks; a command-count/timing sanity check via `/profile`.
  - `test/ui/image_app.fnl` + `test_image.bb` — `[:image {:src ...}]`
    against a small checked-in PNG, covering the four fit modes and
    the missing-file placeholder.
- **Perf validation:** a synthetic 58-sprite 64×96 provider must
  render well under 2 ms (reported baseline: 22.7 ms).
- **Release build check:** bare `odin build` still compiles (texture
  package has no dev-gated code).

## Documentation

- `docs/reference/canvas.md` — `pixels` and `image` ops with the
  data-format contract and the decode-once-cache-string pattern.
- `docs/core-api.md` — `:src` and `:fit` attributes on the image
  element; placeholder wording removed.

## Follow-ups (out of scope)

- Intrinsic sizing: `[:image]` deriving its layout size from the
  texture when `width`/`height` are absent.
- TODO: concept-graph integration of the texture store (blend:deduce)
  if skipped at spec time.
