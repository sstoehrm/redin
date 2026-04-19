# Performance Profiling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in performance profiling (`--profile` flag) that captures per-phase frame timings into a 120-frame ring buffer, draws an on-screen overlay, and exposes the data through `/profile` on the dev server.

**Architecture:** A new `profile` package owns a fixed-size ring of `FrameSample` records (5 phases + total). Phase scopes (`profile.begin`/`profile.end`) bracket the five coarse sections of the main loop: Input, Bridge, Devserver, Layout, Render. Collection is a no-op when the flag is off. A precursor refactor splits `render_tree` into `layout_tree` (writes `node_rects`, no Raylib calls) and `draw_tree` (reads `node_rects`, issues draw calls) so Layout and Render can be measured independently.

**Tech Stack:** Odin (`core:time`, `core:sync`), Raylib (overlay drawing, F3 key), Babashka (integration test).

**Spec:** `docs/superpowers/specs/2026-04-19-performance-profiling-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/host/render.odin` | Split `render_tree` into `layout_tree` + `draw_tree`; keep existing helpers |
| `src/host/profile/profile.odin` | Ring buffer, `init`, `begin_frame`/`end_frame`, `Scope`/`begin`/`end`, `snapshot`, `is_enabled` |
| `src/host/profile/overlay.odin` | `draw_overlay` (panel + graph), F3 toggle |
| `src/host/profile/profile_test.odin` | Unit tests (ring fill/wrap/no-op) |
| `src/host/bridge/devserver.odin` | Route `GET /profile` → `handle_get_profile` |
| `src/host/main.odin` | Parse `--profile`, init profile, wrap phases in scopes, split draw call site, call `draw_overlay` |
| `test/ui/profile_app.fnl` | Minimal app for integration test |
| `test/ui/test_profile.bb` | Babashka integration test |
| `CLAUDE.md` | Add `/profile` row to dev-server table |
| `docs/reference/dev-server.md` | Document `/profile` response schema |

---

### Task 1: Split render_tree into layout_tree and draw_tree

**Why first:** Separating rect computation from Raylib calls is a prerequisite for Task 3 — otherwise the "Layout" phase's timing is meaningless. This task has no user-visible effect; UI tests must still pass at the end.

**Files:**
- Modify: `src/host/render.odin`

- [ ] **Step 1: Add `node_content_rects` parallel array**

Container nodes apply padding and produce a smaller content rect that the draw pass needs (for scissor clipping in scroll containers, and for per-type nuances). Store it alongside `node_rects` so draw doesn't have to recompute padding.

In `src/host/render.odin`, right below the existing `node_rects` declaration (around line 32):

```odin
// Layout rects populated during render, indexed by node idx.
// Used by input handling for hit testing in the next frame.
node_rects: [dynamic]rl.Rectangle

// Content rects (post-padding) for container nodes. Populated by
// layout_tree alongside node_rects. Only meaningful for Vbox, Hbox,
// Canvas, Stack, Popout, Modal. Draw phase reads this for scissor
// clipping and to avoid recomputing padding.
node_content_rects: [dynamic]rl.Rectangle
```

- [ ] **Step 2: Add `layout_tree` and `layout_node` (pure computation, no draw calls)**

This is the rect-computation half of `render_node`. Structure mirrors `render_node` so the split stays legible. Scissor/scroll offsets are computed here (they affect child positions); Raylib draw calls are deferred to the draw phase.

Add these procs to `src/host/render.odin` (before the existing `render_tree`):

```odin
layout_tree :: proc(
    theme: map[string]types.Theme,
    nodes: []types.Node,
    children_list: []types.Children,
) {
    if len(nodes) == 0 do return

    resize(&node_rects, len(nodes))
    resize(&node_content_rects, len(nodes))
    for i in 0 ..< len(nodes) {
        node_rects[i] = {}
        node_content_rects[i] = {}
    }

    screen := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
    layout_node(0, screen, nodes, children_list, theme)
}

layout_node :: proc(
    idx: int,
    rect: rl.Rectangle,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    if idx < 0 || idx >= len(nodes) do return
    node_rects[idx] = rect
    node_content_rects[idx] = rect

    switch n in nodes[idx] {
    case types.NodeStack:
        if len(n.viewport) > 0 {
            layout_children_viewport(idx, n, nodes, children_list, theme)
        } else {
            layout_children_stack(idx, rect, nodes, children_list, theme)
        }
    case types.NodeVbox:
        layout_box(idx, rect, n.aspect, n.layout, true, n.overflow, nodes, children_list, theme)
    case types.NodeHbox:
        layout_box(idx, rect, n.aspect, n.layout, false, n.overflow, nodes, children_list, theme)
    case types.NodeCanvas:
        // Apply padding to content_rect; draw pass uses this for canvas.process.
        content_rect := rect
        if len(n.aspect) > 0 {
            if t, ok := theme[n.aspect]; ok {
                if t.padding != {} {
                    content_rect = rl.Rectangle{
                        rect.x + f32(t.padding[3]),
                        rect.y + f32(t.padding[0]),
                        rect.width - f32(t.padding[1]) - f32(t.padding[3]),
                        rect.height - f32(t.padding[0]) - f32(t.padding[2]),
                    }
                }
            }
        }
        node_content_rects[idx] = content_rect
    case types.NodeInput, types.NodeButton, types.NodeText, types.NodeImage:
        // Leaf — no children, rect already stored.
    case types.NodePopout:
        layout_children_stack(idx, rect, nodes, children_list, theme)
    case types.NodeModal:
        screen := rl.Rectangle{0, 0, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
        node_rects[idx] = screen
        node_content_rects[idx] = screen
        layout_children_stack(idx, screen, nodes, children_list, theme)
    }
}

layout_children_stack :: proc(
    idx: int,
    rect: rl.Rectangle,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    ch := children_list[idx]
    for i in 0 ..< int(ch.length) {
        child_idx := int(ch.value[i])
        layout_node(child_idx, rect, nodes, children_list, theme)
    }
}

layout_children_viewport :: proc(
    idx: int,
    stack: types.NodeStack,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    ch := children_list[idx]
    if int(ch.length) != len(stack.viewport) do return

    win_w := f32(rl.GetScreenWidth())
    win_h := f32(rl.GetScreenHeight())

    for i in 0 ..< int(ch.length) {
        vr := stack.viewport[i]
        w := px(resolve_vp(vr.w, win_w))
        h := px(resolve_vp(vr.h, win_h))
        offset_x := px(resolve_vp(vr.x, win_w))
        offset_y := px(resolve_vp(vr.y, win_h))

        x: f32; y: f32
        #partial switch vr.anchor {
        case .TOP_LEFT, .CENTER_LEFT, .BOTTOM_LEFT:     x = offset_x
        case .TOP_CENTER, .CENTER, .BOTTOM_CENTER:      x = win_w / 2 - w / 2 + offset_x
        case .TOP_RIGHT, .CENTER_RIGHT, .BOTTOM_RIGHT:  x = win_w - w + offset_x
        }
        #partial switch vr.anchor {
        case .TOP_LEFT, .TOP_CENTER, .TOP_RIGHT:        y = offset_y
        case .CENTER_LEFT, .CENTER, .CENTER_RIGHT:      y = win_h / 2 - h / 2 + offset_y
        case .BOTTOM_LEFT, .BOTTOM_CENTER, .BOTTOM_RIGHT: y = win_h - h + offset_y
        }
        child_rect := rl.Rectangle{px(x), px(y), w, h}
        child_idx := int(ch.value[i])
        layout_node(child_idx, child_rect, nodes, children_list, theme)
    }
}

layout_box :: proc(
    idx: int,
    rect: rl.Rectangle,
    aspect: string,
    layout: types.Anchor,
    vertical: bool,
    overflow: string,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    content_rect := rect
    pad: [4]u8
    if len(aspect) > 0 {
        if t, ok := theme[aspect]; ok do pad = t.padding
        if input.dragging_idx == idx {
            drag_start_key := strings.concatenate({aspect, "#drag-start"}, context.temp_allocator)
            if dt, ok := theme[drag_start_key]; ok && dt.padding != {} do pad = dt.padding
        }
        if input.drag_over_idx == idx {
            drag_key := strings.concatenate({aspect, "#drag"}, context.temp_allocator)
            if dt, ok := theme[drag_key]; ok && dt.padding != {} do pad = dt.padding
        }
        if pad != {} {
            content_rect = rl.Rectangle{
                rect.x + f32(pad[3]),
                rect.y + f32(pad[0]),
                rect.width - f32(pad[1]) - f32(pad[3]),
                rect.height - f32(pad[0]) - f32(pad[2]),
            }
        }
    }
    node_content_rects[idx] = content_rect

    ch := children_list[idx]
    if ch.length == 0 do return

    scrollable_y := overflow == "scroll-y" && vertical
    scrollable_x := overflow == "scroll-x" && !vertical
    scrollable := scrollable_y || scrollable_x

    // Size pass — identical math to the existing draw_box, just copied.
    fixed_total: f32 = 0
    fill_count: int = 0
    for i in 0 ..< int(ch.length) {
        child_idx := int(ch.value[i])
        s: f32
        if vertical {
            s = scrollable_y \
                ? intrinsic_height(child_idx, nodes, children_list, theme, content_rect.width) \
                : node_preferred_height(child_idx, nodes, theme, content_rect.width)
        } else {
            s = node_preferred_width(child_idx, nodes)
        }
        if s > 0 do fixed_total += s
        else     do fill_count += 1
    }

    available := vertical ? content_rect.height : content_rect.width
    fill_size: f32 = 0
    if !scrollable && fill_count > 0 {
        remaining := available - fixed_total
        if remaining > 0 do fill_size = remaining / f32(fill_count)
    }

    // Scroll offset — clamp + persist in the same package-level map.
    scroll_off: f32 = 0
    if scrollable_y {
        scroll_off = scroll_offsets[idx] if idx in scroll_offsets else 0
        max_scroll := fixed_total - content_rect.height
        if max_scroll < 0 do max_scroll = 0
        if scroll_off > max_scroll do scroll_off = max_scroll
        if scroll_off < 0 do scroll_off = 0
        scroll_offsets[idx] = scroll_off
    } else if scrollable_x {
        scroll_off = scroll_offsets_x[idx] if idx in scroll_offsets_x else 0
        max_scroll := fixed_total - content_rect.width
        if max_scroll < 0 do max_scroll = 0
        if scroll_off > max_scroll do scroll_off = max_scroll
        if scroll_off < 0 do scroll_off = 0
        scroll_offsets_x[idx] = scroll_off
    }

    // Anchor axes
    anchor_h: int = 0; anchor_v: int = 0
    #partial switch layout {
    case .TOP_CENTER, .CENTER, .BOTTOM_CENTER:        anchor_h = 1
    case .TOP_RIGHT, .CENTER_RIGHT, .BOTTOM_RIGHT:    anchor_h = 2
    }
    #partial switch layout {
    case .CENTER_LEFT, .CENTER, .CENTER_RIGHT:        anchor_v = 1
    case .BOTTOM_LEFT, .BOTTOM_CENTER, .BOTTOM_RIGHT: anchor_v = 2
    }

    pos := (vertical ? content_rect.y : content_rect.x) - scroll_off
    if fill_count == 0 {
        if vertical {
            if anchor_v == 1 do pos = content_rect.y + (available - fixed_total) / 2 - scroll_off
            else if anchor_v == 2 do pos = content_rect.y + available - fixed_total - scroll_off
        } else {
            if anchor_h == 1 do pos = content_rect.x + (available - fixed_total) / 2 - scroll_off
            else if anchor_h == 2 do pos = content_rect.x + available - fixed_total - scroll_off
        }
    }

    for i in 0 ..< int(ch.length) {
        child_idx := int(ch.value[i])
        child_rect: rl.Rectangle
        if vertical {
            h := scrollable_y \
                ? intrinsic_height(child_idx, nodes, children_list, theme, content_rect.width) \
                : node_preferred_height(child_idx, nodes, theme, content_rect.width)
            if h <= 0 do h = fill_size
            child_x := content_rect.x; child_w := content_rect.width
            if anchor_h > 0 {
                w := node_preferred_width(child_idx, nodes)
                if w > 0 {
                    child_x = anchor_h == 1 \
                        ? content_rect.x + (content_rect.width - w) / 2 \
                        : content_rect.x + content_rect.width - w
                    child_w = w
                }
            }
            child_rect = rl.Rectangle{child_x, pos, child_w, h}
            pos += h
        } else {
            w := node_preferred_width(child_idx, nodes)
            if w <= 0 do w = fill_size
            child_y := content_rect.y; child_h := content_rect.height
            if anchor_v > 0 {
                h := node_preferred_height(child_idx, nodes, theme, w)
                if h > 0 {
                    child_y = anchor_v == 1 \
                        ? content_rect.y + (content_rect.height - h) / 2 \
                        : content_rect.y + content_rect.height - h
                    child_h = h
                }
            }
            child_rect = rl.Rectangle{pos, child_y, w, child_h}
            pos += w
        }
        layout_node(child_idx, child_rect, nodes, children_list, theme)
    }
}
```

- [ ] **Step 3: Verify build after adding layout procs**

Run: `odin build src/host -out:build/redin`
Expected: build succeeds. No behavior change yet — `layout_tree` is dead code.

- [ ] **Step 4: Add `draw_tree` and `draw_node` (reads node_rects, issues Raylib calls)**

Draw pass reads the rects written by layout and issues all Raylib draw calls. Leaf draws (`draw_input`, `draw_button`, `draw_text`, `draw_themed_rect`) remain untouched — they already take a `rect` argument.

Add to `src/host/render.odin`:

```odin
draw_tree :: proc(
    theme: map[string]types.Theme,
    nodes: []types.Node,
    children_list: []types.Children,
) {
    if len(nodes) == 0 do return
    draw_node(0, nodes, children_list, theme)
}

draw_node :: proc(
    idx: int,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    if idx < 0 || idx >= len(nodes) do return
    rect := node_rects[idx]
    content_rect := node_content_rects[idx]

    switch n in nodes[idx] {
    case types.NodeStack:
        draw_children(idx, nodes, children_list, theme)
    case types.NodeVbox:
        draw_box_chrome(idx, rect, n.aspect, n.overflow, true, theme)
        draw_box_children(idx, content_rect, n.overflow, true, nodes, children_list, theme)
    case types.NodeHbox:
        draw_box_chrome(idx, rect, n.aspect, n.overflow, false, theme)
        draw_box_children(idx, content_rect, n.overflow, false, nodes, children_list, theme)
    case types.NodeCanvas:
        // Draw theme chrome on rect, then canvas.process on content_rect.
        if len(n.aspect) > 0 {
            if t, ok := theme[n.aspect]; ok {
                draw_shadow(rect, t.shadow, t.radius)
                if t.bg != {} {
                    bg := rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
                    if t.radius > 0 {
                        roundness := f32(t.radius) / min(rect.width, rect.height) * 2
                        rl.DrawRectangleRounded(rect, roundness, 6, bg)
                    } else {
                        rl.DrawRectangleRec(rect, bg)
                    }
                }
                if t.border != {} && t.border_width > 0 {
                    border := rl.Color{t.border[0], t.border[1], t.border[2], 255}
                    if t.radius > 0 {
                        roundness := f32(t.radius) / min(rect.width, rect.height) * 2
                        rl.DrawRectangleRoundedLinesEx(rect, roundness, 6, f32(t.border_width), border)
                    } else {
                        rl.DrawRectangleLinesEx(rect, f32(t.border_width), border)
                    }
                }
            }
        }
        if len(n.provider) > 0 {
            canvas.process(n.provider, content_rect)
        } else {
            rl.DrawRectangleLinesEx(content_rect, 1, rl.LIGHTGRAY)
            rl.DrawText("canvas", i32(content_rect.x) + 4, i32(content_rect.y) + 4, 16, rl.GRAY)
        }
    case types.NodeInput:
        draw_input(idx, rect, n, theme)
    case types.NodeButton:
        draw_button(rect, n, theme)
    case types.NodeText:
        draw_text(idx, rect, n, theme)
    case types.NodeImage:
        draw_themed_rect(rect, n.aspect, theme)
        rl.DrawRectangleLinesEx(rect, 1, rl.GRAY)
        rl.DrawText("image", i32(rect.x) + 4, i32(rect.y) + 4, 14, rl.GRAY)
    case types.NodePopout:
        draw_children(idx, nodes, children_list, theme)
    case types.NodeModal:
        draw_themed_rect(rect, n.aspect, theme)
        draw_children(idx, nodes, children_list, theme)
    }
}

draw_children :: proc(
    idx: int,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    ch := children_list[idx]
    for i in 0 ..< int(ch.length) {
        draw_node(int(ch.value[i]), nodes, children_list, theme)
    }
}

// Chrome = shadow + bg + border, derived from theme + drag state.
draw_box_chrome :: proc(
    idx: int,
    rect: rl.Rectangle,
    aspect: string,
    overflow: string,
    vertical: bool,
    theme: map[string]types.Theme,
) {
    if len(aspect) == 0 do return

    bg_color: rl.Color
    has_bg := false
    shadow: types.Shadow

    if t, ok := theme[aspect]; ok {
        if t.bg != {} {
            alpha := u8(255)
            if t.opacity > 0 && t.opacity < 1 do alpha = u8(t.opacity * 255)
            bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], alpha}
            has_bg = true
        }
        shadow = t.shadow
    }
    if input.dragging_idx == idx {
        drag_start_key := strings.concatenate({aspect, "#drag-start"}, context.temp_allocator)
        if dt, ok := theme[drag_start_key]; ok && dt.bg != {} {
            bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
            has_bg = true
        }
    }
    if input.drag_over_idx == idx {
        drag_key := strings.concatenate({aspect, "#drag"}, context.temp_allocator)
        if dt, ok := theme[drag_key]; ok && dt.bg != {} {
            bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
            has_bg = true
        }
    }

    draw_shadow(rect, shadow, 0)
    if has_bg do rl.DrawRectangleRec(rect, bg_color)
}

// Children + scroll scissor + scrollbar. Reads node_rects for each child.
draw_box_children :: proc(
    idx: int,
    content_rect: rl.Rectangle,
    overflow: string,
    vertical: bool,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    ch := children_list[idx]
    if ch.length == 0 do return

    scrollable_y := overflow == "scroll-y" && vertical
    scrollable_x := overflow == "scroll-x" && !vertical
    scrollable := scrollable_y || scrollable_x

    if scrollable {
        rl.BeginScissorMode(
            i32(content_rect.x), i32(content_rect.y),
            i32(content_rect.width), i32(content_rect.height),
        )
    }

    for i in 0 ..< int(ch.length) {
        draw_node(int(ch.value[i]), nodes, children_list, theme)
    }

    if scrollable {
        rl.EndScissorMode()

        // Scrollbar — read the same totals layout just computed. We recompute
        // fixed_total here because it wasn't stored; the cost is tiny and this
        // is only in the draw path for scroll containers.
        fixed_total: f32 = 0
        for i in 0 ..< int(ch.length) {
            child_idx := int(ch.value[i])
            s: f32 = vertical \
                ? (scrollable_y \
                    ? intrinsic_height(child_idx, nodes, children_list, theme, content_rect.width) \
                    : node_preferred_height(child_idx, nodes, theme, content_rect.width)) \
                : node_preferred_width(child_idx, nodes)
            if s > 0 do fixed_total += s
        }
        scroll_off := scrollable_y \
            ? (scroll_offsets[idx] if idx in scroll_offsets else 0) \
            : (scroll_offsets_x[idx] if idx in scroll_offsets_x else 0)

        if scrollable_y && fixed_total > content_rect.height {
            bar_w: f32 = 4
            bar_x := content_rect.x + content_rect.width - bar_w
            visible_ratio := content_rect.height / fixed_total
            bar_h := max(content_rect.height * visible_ratio, 20)
            max_scroll := fixed_total - content_rect.height
            scroll_ratio := scroll_off / max_scroll if max_scroll > 0 else 0
            bar_y := content_rect.y + scroll_ratio * (content_rect.height - bar_h)
            rl.DrawRectangleRounded(
                {bar_x, bar_y, bar_w, bar_h}, 1, 4, rl.Color{200, 200, 200, 120},
            )
        } else if scrollable_x && fixed_total > content_rect.width {
            bar_h: f32 = 4
            bar_y := content_rect.y + content_rect.height - bar_h
            visible_ratio := content_rect.width / fixed_total
            bar_w := max(content_rect.width * visible_ratio, 20)
            max_scroll := fixed_total - content_rect.width
            scroll_ratio := scroll_off / max_scroll if max_scroll > 0 else 0
            bar_x := content_rect.x + scroll_ratio * (content_rect.width - bar_w)
            rl.DrawRectangleRounded(
                {bar_x, bar_y, bar_w, bar_h}, 1, 4, rl.Color{200, 200, 200, 120},
            )
        }
    }
}
```

- [ ] **Step 5: Replace `render_tree` with sequential calls**

Rewrite the old `render_tree` to be a thin wrapper — this keeps existing call sites in `main.odin` working until Step 7 rewires them.

Replace the existing `render_tree` procedure (`src/host/render.odin:96-111`) with:

```odin
render_tree :: proc(
    theme: map[string]types.Theme,
    nodes: []types.Node,
    children_list: []types.Children,
) {
    layout_tree(theme, nodes, children_list)
    draw_tree(theme, nodes, children_list)
}
```

- [ ] **Step 6: Delete `render_node`, `render_children_stack`, `render_children_viewport`, `draw_box`**

These are now dead code — `layout_*` + `draw_*` replace them.

Delete from `src/host/render.odin`:
- `render_node` (starting at old line 113)
- `render_children_stack` (starting at old line 209)
- `render_children_viewport` (starting at old line 224)
- `draw_box` (starting at old line 275)

Keep: `draw_shadow`, `draw_themed_rect`, `draw_input`, `draw_button`, `draw_text`, `node_preferred_width`, `node_preferred_height`, `intrinsic_height`, `size_f32`, `size_f16`, `px`, `resolve_vp`, `apply_scroll_events`, `find_deepest_overflow`.

- [ ] **Step 7: Verify build, run UI tests**

Build: `odin build src/host -out:build/redin`
Expected: build succeeds.

Run existing UI tests to confirm layout/draw split is behavior-preserving:

```bash
./build/redin --dev test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
# Expected: all tests pass
curl -X POST http://localhost:$(cat .redin-port)/shutdown

./build/redin --dev test/ui/input_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_input.bb
# Expected: all tests pass
curl -X POST http://localhost:$(cat .redin-port)/shutdown
```

- [ ] **Step 8: Commit**

```bash
git add src/host/render.odin
git commit -m "$(cat <<'EOF'
refactor(render): split render_tree into layout_tree + draw_tree

Separates rect computation (layout_tree, writes node_rects and
node_content_rects) from Raylib draw calls (draw_tree). Prerequisite for
measuring the Layout and Render phases independently in the upcoming
profile package. Behavior-preserving; render_tree remains as a thin
wrapper that runs both passes.
EOF
)"
```

---

### Task 2: Create profile package

**Why TDD here:** Ring buffer semantics (fill, wrap, no-op) are pure logic with easy assertions. Tests drive a minimal, correct implementation.

**Files:**
- Create: `src/host/profile/profile.odin`
- Create: `src/host/profile/profile_test.odin`

- [ ] **Step 1: Write the failing ring-fill test**

Create `src/host/profile/profile_test.odin`:

```odin
package profile

import "core:testing"

@(test)
test_ring_fill_short :: proc(t: ^testing.T) {
    init(true)
    defer init(false) // reset

    for i in 0 ..< 30 {
        begin_frame()
        end_frame()
    }

    samples := make([dynamic]FrameSample)
    defer delete(samples)
    snapshot_into(&samples)

    testing.expect_value(t, len(samples), 30)
    testing.expect_value(t, samples[0].frame_idx, u64(0))
    testing.expect_value(t, samples[29].frame_idx, u64(29))
}

@(test)
test_ring_wrap :: proc(t: ^testing.T) {
    init(true)
    defer init(false)

    for i in 0 ..< 200 {
        begin_frame()
        end_frame()
    }

    samples := make([dynamic]FrameSample)
    defer delete(samples)
    snapshot_into(&samples)

    // Ring holds 120, written 200 → oldest surviving is idx 80, newest is 199.
    testing.expect_value(t, len(samples), FRAME_CAP)
    testing.expect_value(t, samples[0].frame_idx, u64(80))
    testing.expect_value(t, samples[FRAME_CAP - 1].frame_idx, u64(199))
}

@(test)
test_disabled_is_noop :: proc(t: ^testing.T) {
    init(false)

    begin_frame()
    s := begin(.Input)
    end(s)
    end_frame()

    samples := make([dynamic]FrameSample)
    defer delete(samples)
    snapshot_into(&samples)

    testing.expect_value(t, len(samples), 0)
    testing.expect_value(t, is_enabled(), false)
}
```

- [ ] **Step 2: Run tests to verify they fail (package missing)**

Run: `odin test src/host/profile`
Expected: compile error — `package profile` does not exist yet.

- [ ] **Step 3: Implement the minimal profile package**

Create `src/host/profile/profile.odin`:

```odin
package profile

import "core:sync"
import "core:time"

FRAME_CAP :: 120

Phase :: enum { Input, Bridge, Layout, Render, Devserver }

FrameSample :: struct {
    frame_idx: u64,
    total_ns:  i64,
    phase_ns:  [Phase]i64,
}

Ring :: struct {
    samples: [FRAME_CAP]FrameSample,
    head:    int,
    count:   int,
    next_id: u64,
}

Scope :: struct {
    phase: Phase,
    start: time.Tick,
    live:  bool, // zero-valued Scopes from the no-op path are skipped
}

@(private) enabled_flag: bool
@(private) visible_flag: bool
@(private) ring:         Ring
@(private) snapshot_mu:  sync.Mutex

// Per-frame scratch state — populated by begin/end, flushed by end_frame.
@(private) frame_start:    time.Tick
@(private) phase_scratch:  [Phase]i64

is_enabled :: proc() -> bool { return enabled_flag }

overlay_visible :: proc() -> bool { return visible_flag }
set_overlay_visible :: proc(v: bool) { visible_flag = v }

init :: proc(enabled: bool) {
    enabled_flag = enabled
    visible_flag = enabled
    ring = {}
    frame_start = {}
    phase_scratch = {}
}

begin_frame :: proc() {
    if !enabled_flag do return
    frame_start = time.tick_now()
    phase_scratch = {}
}

end_frame :: proc() {
    if !enabled_flag do return
    total := time.tick_diff(frame_start, time.tick_now())

    sync.lock(&snapshot_mu)
    defer sync.unlock(&snapshot_mu)

    sample := FrameSample{
        frame_idx = ring.next_id,
        total_ns  = i64(total),
        phase_ns  = phase_scratch,
    }
    ring.samples[ring.head] = sample
    ring.head = (ring.head + 1) % FRAME_CAP
    if ring.count < FRAME_CAP do ring.count += 1
    ring.next_id += 1
}

begin :: proc(p: Phase) -> Scope {
    if !enabled_flag do return Scope{}
    return Scope{phase = p, start = time.tick_now(), live = true}
}

end :: proc(s: Scope) {
    if !s.live do return
    phase_scratch[s.phase] += i64(time.tick_diff(s.start, time.tick_now()))
}

// Append current ring contents (oldest→newest) to `out`.
snapshot_into :: proc(out: ^[dynamic]FrameSample) {
    sync.lock(&snapshot_mu)
    defer sync.unlock(&snapshot_mu)

    if ring.count == 0 do return
    start := (ring.head - ring.count + FRAME_CAP) % FRAME_CAP
    for i in 0 ..< ring.count {
        append(out, ring.samples[(start + i) % FRAME_CAP])
    }
}

phase_name :: proc(p: Phase) -> string {
    switch p {
    case .Input:     return "input"
    case .Bridge:    return "bridge"
    case .Layout:    return "layout"
    case .Render:    return "render"
    case .Devserver: return "devserver"
    }
    return "?"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `odin test src/host/profile`
Expected: `test_ring_fill_short`, `test_ring_wrap`, `test_disabled_is_noop` all pass.

- [ ] **Step 5: Verify host still builds**

Run: `odin build src/host -out:build/redin`
Expected: build succeeds (profile package compiles as part of src/host's dependency graph).

- [ ] **Step 6: Commit**

```bash
git add src/host/profile/profile.odin src/host/profile/profile_test.odin
git commit -m "$(cat <<'EOF'
feat(profile): add profile package with ring buffer and TDD tests

Introduces the profile package housing a 120-frame ring of
FrameSample records (5 phases + total), scope-based begin/end API, and
snapshot_into for readers. No call sites yet; next commit wires the
main loop.
EOF
)"
```

---

### Task 3: Wire --profile flag and phase scopes into main.odin

**Files:**
- Modify: `src/host/main.odin`

- [ ] **Step 1: Parse `--profile` flag and call `profile.init`**

Replace the arg loop and opening section of `main.odin` with:

```odin
package host

import "bridge"
import "canvas"
import "core:fmt"
import "core:mem"
import "core:os"
import "font"
import "input"
import "profile"
import "types"
import rl "vendor:raylib"

main :: proc() {
    dev_mode := false
    track_mem := false
    profile_mode := false
    app_file := ""
    for arg in os.args[1:] {
        switch arg {
        case "--dev":        dev_mode = true
        case "--track-mem":  track_mem = true
        case "--profile":    profile_mode = true
        case:                app_file = arg
        }
    }

    // (keep existing mem.Tracking_Allocator block as-is)
```

Keep the rest of main body unchanged for now — mem tracking block, window init, etc.

After `font.init()` / before `bridge.init`, add:

```odin
    profile.init(profile_mode)
```

- [ ] **Step 2: Wrap main-loop phases in begin/end scopes**

Rewrite the main loop body in `src/host/main.odin`. Replace the existing loop (lines 73–139) with:

```odin
    for !rl.WindowShouldClose() && !bridge.is_shutdown_requested(&b) {
        profile.begin_frame()

        free_all(context.temp_allocator)
        bridge.check_hotreload(&b)

        if b.frame_changed {
            delete(listeners)
            listeners = input.extract_listeners(b.paths, b.nodes, b.theme)
        }

        // --- Input: poll raw events ---
        s_input1 := profile.begin(.Input)
        input_events := input.poll()
        profile.end(s_input1)
        defer delete(input_events)

        // --- Devserver: drain pending HTTP requests ---
        s_ds := profile.begin(.Devserver)
        bridge.poll_devserver(&b, &input_events)
        profile.end(s_ds)

        // --- Bridge: all Lua-side work ---
        s_br1 := profile.begin(.Bridge)
        bridge.deliver_events(&b, input_events[:])
        bridge.poll_http(&b)
        bridge.poll_shell(&b)
        bridge.render_tick(&b)
        bridge.poll_timers(&b)
        profile.end(s_br1)

        // --- Input: post-processing (continues Input phase) ---
        s_input2 := profile.begin(.Input)
        user_events := input.get_user_events(input_events, listeners, node_rects[:])
        defer delete(user_events)
        applied_events := input.apply_listeners(listeners, input_events, node_rects[:])
        defer delete(applied_events)

        for ae in applied_events {
            switch a in ae {
            case types.ApplyFocus:
                if a.idx < len(b.nodes) {
                    if n, ok := b.nodes[a.idx].(types.NodeInput); ok {
                        input.focus_enter(n.value)
                    } else {
                        input.focus_leave()
                    }
                }
            case types.ApplyActive:
            }
        }
        if input.state.active && input.focused_idx < 0 {
            input.focus_leave()
        }

        drag_events := input.process_drag(
            input_events[:], listeners[:], b.nodes[:], node_rects[:],
        )
        defer delete(drag_events)
        dispatch_events := input.process_user_events(
            user_events[:], input_events[:], b.nodes[:], node_rects[:], b.theme,
        )
        defer delete(dispatch_events)
        apply_scroll_events(input_events[:], b.nodes[:])
        profile.end(s_input2)

        // --- Bridge: event delivery back into Lua ---
        s_br2 := profile.begin(.Bridge)
        bridge.deliver_dispatch_events(&b, drag_events[:])
        bridge.deliver_dispatch_events(&b, dispatch_events[:])
        profile.end(s_br2)

        rl.BeginDrawing()
        rl.ClearBackground({255, 255, 255, 255})

        s_layout := profile.begin(.Layout)
        layout_tree(b.theme, b.nodes[:], b.children_list[:])
        profile.end(s_layout)

        s_render := profile.begin(.Render)
        draw_tree(b.theme, b.nodes[:], b.children_list[:])
        profile.end(s_render)

        profile.draw_overlay()
        canvas.end_frame()
        rl.EndDrawing()

        profile.end_frame()
    }
```

Notes:
- `render_tree` is no longer called — replaced by explicit `layout_tree` then `draw_tree` with phase scopes around each.
- Input post-processing is timed under `.Input` via a second scope; per-phase scratch accumulates so the reported `input` time sums both halves.
- Event delivery after drag/dispatch computation is folded into `.Bridge` since the cost is Lua round-trips.
- All the previous `defer delete(...)` calls are preserved; they now sit below their populating scopes so lifetimes still span the whole frame.

- [ ] **Step 3: Verify build**

Run: `odin build src/host -out:build/redin`
Expected: build succeeds.

- [ ] **Step 4: Smoke-test with and without --profile**

```bash
./build/redin examples/kitchen-sink.fnl &
sleep 1
# Expected: window runs normally, no overlay, no profile data.
ps aux | grep redin
kill %1

./build/redin --profile examples/kitchen-sink.fnl &
sleep 1
# Expected: window runs normally. No overlay visible yet (Task 4 adds drawing).
# Data is being collected internally but not exposed.
kill %1
```

- [ ] **Step 5: Commit**

```bash
git add src/host/main.odin
git commit -m "$(cat <<'EOF'
feat(profile): wire --profile flag and phase scopes into main loop

Adds --profile CLI flag, calls profile.init, and brackets Input, Bridge,
Devserver, Layout, and Render phases with scope-based begin/end. Uses
the new layout_tree/draw_tree split so Layout and Render are
independently measurable.
EOF
)"
```

---

### Task 4: Implement overlay

**Files:**
- Create: `src/host/profile/overlay.odin`
- Modify: `src/host/main.odin`

- [ ] **Step 1: Implement `draw_overlay`**

Create `src/host/profile/overlay.odin`:

```odin
package profile

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

OVERLAY_W :: 180
OVERLAY_H :: 110
PAD       :: 6
LINE_H    :: 14
GRAPH_H   :: 30

// Called from main.odin between draw_tree and canvas.end_frame. Toggles on F3.
draw_overlay :: proc() {
    if !enabled_flag do return

    if rl.IsKeyPressed(.F3) {
        visible_flag = !visible_flag
    }
    if !visible_flag do return

    snap := make([dynamic]FrameSample, context.temp_allocator)
    snapshot_into(&snap)
    if len(snap) == 0 do return

    screen_w := f32(rl.GetScreenWidth())
    x0 := i32(screen_w) - OVERLAY_W - 8
    y0: i32 = 8

    // Background panel
    rl.DrawRectangle(x0, y0, OVERLAY_W, OVERLAY_H, rl.Color{0, 0, 0, 180})

    last := snap[len(snap) - 1]
    total_ms := f32(last.total_ns) / 1_000_000.0
    fps: int = total_ms > 0 ? int(1000.0 / total_ms + 0.5) : 0

    buf: [64]u8

    // Line 1: FPS + total
    head := fmt.bprintf(buf[:], "FPS %-3d  frame %.1fms", fps, total_ms)
    draw_label(x0 + PAD, y0 + PAD, head)

    // Phase lines
    line_i := 0
    for phase in Phase {
        ms := f32(last.phase_ns[phase]) / 1_000_000.0
        name := phase_name(phase)
        line := fmt.bprintf(buf[:], "%-9s %4.1fms", name, ms)
        draw_label(x0 + PAD, y0 + PAD + i32(LINE_H * (1 + line_i)), line)
        line_i += 1
    }

    // Mini graph along the bottom
    gx0 := x0 + PAD
    gy0 := y0 + OVERLAY_H - GRAPH_H - PAD
    rl.DrawRectangle(gx0, gy0, OVERLAY_W - PAD * 2, GRAPH_H, rl.Color{20, 20, 20, 200})

    bar_w: i32 = 1
    budget_ns: f32 = 33_000_000.0 // 33 ms full-height, two frames at 60 FPS
    for s, i in snap {
        h := f32(s.total_ns) / budget_ns
        if h > 1.0 do h = 1.0
        bar_h := i32(h * f32(GRAPH_H))
        col := s.total_ns > 16_666_667 ? rl.Color{220, 70, 70, 220} : rl.Color{80, 200, 120, 220}
        rl.DrawRectangle(gx0 + i32(i) * bar_w, gy0 + GRAPH_H - bar_h, bar_w, bar_h, col)
    }
}

@(private)
draw_label :: proc(x, y: i32, s: string) {
    cstr := strings.clone_to_cstring(s, context.temp_allocator)
    rl.DrawText(cstr, x, y, 10, rl.Color{230, 230, 230, 255})
}
```

- [ ] **Step 2: Hook `draw_overlay` into the main loop**

In `src/host/main.odin`, inside the main loop's draw section, add the overlay call between `draw_tree` and `canvas.end_frame()`:

```odin
        {
            s := profile.begin(.Render); defer profile.end(s)
            draw_tree(b.theme, b.nodes[:], b.children_list[:])
        }

        profile.draw_overlay()
        canvas.end_frame()
        rl.EndDrawing()
```

The overlay draw itself is not counted against the Render phase (it fires after the Render scope closes). This is intentional — the overlay is instrumentation, not part of what we're profiling.

- [ ] **Step 3: Build and eyeball**

```bash
odin build src/host -out:build/redin
./build/redin --profile examples/kitchen-sink.fnl &
sleep 1
# Expected: window opens with a semi-transparent panel in the top-right
# showing FPS, per-phase ms, and a growing bar graph along the bottom.
# Press F3 to hide/show the overlay.
kill %1
```

- [ ] **Step 4: Commit**

```bash
git add src/host/profile/overlay.odin src/host/main.odin
git commit -m "$(cat <<'EOF'
feat(profile): add on-screen overlay toggled with F3

Draws a 180×110 panel in the top-right with FPS, per-phase durations,
and a 120-frame bar graph (red for frames over 16.67 ms). Only active
when --profile is set; F3 toggles visibility at runtime.
EOF
)"
```

---

### Task 5: Add /profile endpoint

**Files:**
- Modify: `src/host/bridge/devserver.odin`

- [ ] **Step 1: Add `handle_get_profile`**

Append to `src/host/bridge/devserver.odin` (near the other `handle_get_*` procs, e.g. after `handle_get_aspects`):

```odin
handle_get_profile :: proc(ch: ^Response_Channel) {
    if !profile.is_enabled() {
        respond_text(ch, 404, "profile not enabled")
        return
    }

    samples := make([dynamic]profile.FrameSample, context.temp_allocator)
    profile.snapshot_into(&samples)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    fmt.sbprintf(&b, `{{"enabled":true,"frame_cap":%d,"count":%d,`,
        profile.FRAME_CAP, len(samples))

    // phases[]
    strings.write_string(&b, `"phases":[`)
    first := true
    for phase in profile.Phase {
        if !first do strings.write_string(&b, ",")
        first = false
        fmt.sbprintf(&b, `"%s"`, profile.phase_name(phase))
    }
    strings.write_string(&b, `],`)

    // frames[]
    strings.write_string(&b, `"frames":[`)
    for s, i in samples {
        if i > 0 do strings.write_string(&b, ",")
        total_us := s.total_ns / 1000
        fmt.sbprintf(&b, `{{"idx":%d,"total_us":%d,"phase_us":[`,
            s.frame_idx, total_us)
        pfirst := true
        for phase in profile.Phase {
            if !pfirst do strings.write_string(&b, ",")
            pfirst = false
            fmt.sbprintf(&b, "%d", s.phase_ns[phase] / 1000)
        }
        strings.write_string(&b, `]}`)
    }
    strings.write_string(&b, `]}`)

    respond_json(ch, strings.to_string(b))
}
```

- [ ] **Step 2: Import the profile package and register the route**

At the top of `src/host/bridge/devserver.odin`, add the import:

```odin
import "../profile"
```

In `process_request` (around line 352), extend the `GET` branch to route `/profile`:

```odin
    case "GET":
        if req.path == "/frames" {
            handle_get_frames(ds, ch)
        } else if req.path == "/state" {
            handle_get_state(ds, ch)
        } else if strings.has_prefix(req.path, "/state/") {
            handle_get_state_path(ds, ch, req.path[len("/state/"):])
        } else if req.path == "/aspects" {
            handle_get_aspects(ds, ch)
        } else if req.path == "/profile" {
            handle_get_profile(ch)
        } else if req.path == "/screenshot" {
            handle_screenshot(ch)
        } else if req.path == "/window" {
            handle_get_window(ch)
        } else {
            respond_text(ch, 404, "Not found")
        }
```

- [ ] **Step 3: Build and curl-test**

```bash
odin build src/host -out:build/redin

# Without --profile: expect 404
./build/redin --dev examples/kitchen-sink.fnl &
sleep 1
curl -i http://localhost:$(cat .redin-port)/profile
# Expected: HTTP/1.1 404 Not Found  body: "profile not enabled"
curl -X POST http://localhost:$(cat .redin-port)/shutdown

# With --profile: expect 200 JSON
./build/redin --dev --profile examples/kitchen-sink.fnl &
sleep 2
curl -s http://localhost:$(cat .redin-port)/profile | head -c 200
# Expected: JSON starting with {"enabled":true,"frame_cap":120,"count":120,"phases":["input","bridge","layout","render","devserver"],"frames":[...
curl -X POST http://localhost:$(cat .redin-port)/shutdown
```

- [ ] **Step 4: Commit**

```bash
git add src/host/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(devserver): add GET /profile endpoint

Exposes the profile ring buffer as JSON when the dev server is running
with --profile. Returns 404 if profiling is not enabled. Units are
microseconds; phase_us is positional and matches the phases[] array.
EOF
)"
```

---

### Task 6: Integration test

**Files:**
- Create: `test/ui/profile_app.fnl`
- Create: `test/ui/test_profile.bb`

- [ ] **Step 1: Create the minimal Fennel test app**

Create `test/ui/profile_app.fnl`:

```fennel
;; Minimal app for profile endpoint integration test.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:body {:font-size 14 :color [216 222 233]}})

(dataflow.init {})

(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
  (fn []
    [:vbox {}
     [:text {:aspect :body} "profile test"]]))
```

The app mirrors `test/ui/smoke_app.fnl`'s structure (theme + dataflow + `main_view` global). The tree is deliberately tiny so framework phase durations dominate any app-specific work in the sample.

- [ ] **Step 2: Write the Babashka test**

Create `test/ui/test_profile.bb`:

```clojure
(require '[redin-test :refer :all]
         '[cheshire.core :as json]
         '[babashka.http-client :as http])

(defn get-profile []
  (let [port (slurp ".redin-port")
        resp (http/get (str "http://localhost:" (clojure.string/trim port) "/profile")
                       {:throw false})]
    {:status (:status resp)
     :body   (when (= 200 (:status resp)) (json/parse-string (:body resp) true))}))

(deftest profile-enabled-shape
  (let [{:keys [status body]} (get-profile)]
    (assert (= 200 status) (str "expected 200, got " status))
    (assert (true? (:enabled body)) ":enabled should be true")
    (assert (= 120 (:frame_cap body)) ":frame_cap should be 120")
    (assert (= ["input" "bridge" "layout" "render" "devserver"]
               (:phases body))
            (str ":phases should match spec, got " (:phases body)))))

(deftest profile-count-grows
  ;; Wait until the ring fills.
  (wait-for (fn [] (= 120 (:count (:body (get-profile))))) {:timeout 4000})
  (let [body (:body (get-profile))]
    (assert (= 120 (:count body)))
    (assert (= 120 (count (:frames body))))))

(deftest profile-phase-sums-near-total
  (let [body (:body (get-profile))]
    (doseq [frame (:frames body)]
      (let [total (:total_us frame)
            phase-sum (apply + (:phase_us frame))]
        ;; Glue code between phases is not timed; allow 10% slack.
        (when (> total 100) ;; ignore frames under 100 µs (timer noise)
          (let [ratio (/ (double phase-sum) (double total))]
            (assert (<= 0.5 ratio 1.1)
                    (str "phase sum " phase-sum " vs total " total
                         " (ratio " ratio ") outside 0.5..1.1"))))))))
```

Note: the ratio window is generous (0.5..1.1) because the Bridge phase is measured in two halves (events + delivery) and the Input phase is measured in two halves (poll + post-process). Glue code (the `free_all`, `if b.frame_changed { ... }` block) isn't timed.

- [ ] **Step 3: Run the test — expect PASS**

Run:

```bash
odin build src/host -out:build/redin
./build/redin --dev --profile test/ui/profile_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_profile.bb
# Expected: all three deftests pass.
curl -X POST http://localhost:$(cat .redin-port)/shutdown
```

- [ ] **Step 4: Verify 404 path**

Run:

```bash
./build/redin --dev test/ui/profile_app.fnl &    # NOTE: no --profile
sleep 1
curl -w "\n%{http_code}\n" http://localhost:$(cat .redin-port)/profile
# Expected: "profile not enabled" followed by 404
curl -X POST http://localhost:$(cat .redin-port)/shutdown
```

- [ ] **Step 5: Commit**

```bash
git add test/ui/profile_app.fnl test/ui/test_profile.bb
git commit -m "$(cat <<'EOF'
test(profile): integration test for /profile endpoint

profile_app.fnl renders a minimal tree; test_profile.bb asserts the
endpoint shape, that the ring fills to 120 frames, and that per-frame
phase durations sum close to total.
EOF
)"
```

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/reference/dev-server.md`

- [ ] **Step 1: Add `/profile` row to CLAUDE.md dev-server table**

In `CLAUDE.md`, find the dev-server table (search for `| GET | \`/aspects\` |`) and insert between the `/aspects` and `/screenshot` rows:

```markdown
| `GET` | `/profile` | Ring-buffered frame timings (requires `--profile`) |
```

Also extend the "AI interface" description (search for `localhost HTTP dev server`) to mention `--profile`:

```markdown
- **AI interface:** localhost HTTP dev server (`--dev` mode). Default port 8800; if busy, walks upward to the next free port. Actual port is written to `./.redin-port` and cleaned up on shutdown. Optional `--profile` flag adds a 5-phase frame-timing ring buffer exposed at `/profile` and an F3-togglable on-screen overlay.
```

- [ ] **Step 2: Add `/profile` section to `docs/reference/dev-server.md`**

In `docs/reference/dev-server.md`, add a new section after the existing `/aspects` documentation:

```markdown
## `GET /profile`

Returns frame-timing samples from the ring buffer. Only registered when the host runs with both `--dev` and `--profile`; otherwise returns `404`.

**Response:**

```json
{
  "enabled": true,
  "frame_cap": 120,
  "count": 120,
  "phases": ["input", "bridge", "layout", "render", "devserver"],
  "frames": [
    {"idx": 4820, "total_us": 14230, "phase_us": [310, 8420, 1890, 3480, 130]}
  ]
}
```

- `frame_cap` — ring size (fixed at 120 frames, ≈2 seconds at 60 FPS).
- `count` — number of samples currently in the ring (grows from 0 to `frame_cap`).
- `phases` — phase names in positional order; matches each frame's `phase_us` array.
- `frames` — oldest first, newest last.
- `idx` — monotonic frame counter since process start.
- Units: microseconds.

The sum of `phase_us` may be slightly less than `total_us` because glue code between phases (event bookkeeping, temp_allocator reset, hotreload check) is not timed.

### CLI flag

`--profile` activates collection and the on-screen overlay (top-right corner). Press `F3` at runtime to hide/show the overlay without restarting. The overlay is independent of `--dev` — you can run `--profile` alone for local eyeballing or `--profile --dev` to expose the endpoint.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/reference/dev-server.md
git commit -m "$(cat <<'EOF'
docs: document /profile endpoint and --profile flag

Adds /profile row to CLAUDE.md's dev-server table and a full response
schema to docs/reference/dev-server.md. Describes the F3 overlay
toggle and the --dev/--profile orthogonality.
EOF
)"
```

---

## Verification (post-plan)

After completing all tasks:

1. `odin build src/host -out:build/redin` — clean build.
2. `odin test src/host/profile` — unit tests green.
3. `odin test src/host/parser` — existing tests still green.
4. `luajit test/lua/runner.lua test/lua/test_*.fnl` — Fennel tests still green.
5. `./build/redin --dev test/ui/smoke_app.fnl &; bb test/ui/run.bb test/ui/test_smoke.bb` — smoke UI test passes (verifies the render split didn't regress).
6. `./build/redin --dev test/ui/input_app.fnl &; bb test/ui/run.bb test/ui/test_input.bb` — input UI test passes.
7. `./build/redin --dev --profile test/ui/profile_app.fnl &; bb test/ui/run.bb test/ui/test_profile.bb` — new profile test passes.
8. Eyeball: `./build/redin --profile examples/kitchen-sink.fnl` — overlay visible top-right, F3 toggles, bar graph updates.
