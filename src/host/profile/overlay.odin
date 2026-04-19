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
