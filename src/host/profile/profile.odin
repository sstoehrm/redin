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

// Per-frame scratch state — mutated by begin/end on the main thread only.
// Flushed into the ring by end_frame. Do NOT read from other threads
// (e.g., the devserver handler) — read `ring` via snapshot_into instead.
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
