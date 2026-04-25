package profile

import "core:sync"
import "core:testing"
import "core:time"

// Tests mutate package-level globals; serialize them so Odin's default
// multi-threaded test runner doesn't race.
@(private) test_mu: sync.Mutex

@(test)
test_ring_fill_short :: proc(t: ^testing.T) {
    sync.lock(&test_mu)
    defer sync.unlock(&test_mu)

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
    sync.lock(&test_mu)
    defer sync.unlock(&test_mu)

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
    sync.lock(&test_mu)
    defer sync.unlock(&test_mu)

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

@(test)
test_phase_accumulation :: proc(t: ^testing.T) {
    sync.lock(&test_mu)
    defer sync.unlock(&test_mu)

    init(true)
    defer init(false)

    begin_frame()
    s := begin(.Input)
    // Small spin so the tick delta is non-zero on fast machines.
    time.sleep(100 * time.Microsecond)
    end(s)
    end_frame()

    samples := make([dynamic]FrameSample)
    defer delete(samples)
    snapshot_into(&samples)

    testing.expect_value(t, len(samples), 1)
    sample := samples[0]
    testing.expect(t, sample.phase_ns[.Input] > 0,
        "Input phase should accumulate elapsed ns")
    testing.expect(t, sample.total_ns >= sample.phase_ns[.Input],
        "total_ns should cover the Input phase")
    // Other phases were never measured this frame → zero.
    testing.expect_value(t, sample.phase_ns[.Bridge],    i64(0))
    testing.expect_value(t, sample.phase_ns[.Layout],    i64(0))
    testing.expect_value(t, sample.phase_ns[.Render],    i64(0))
    testing.expect_value(t, sample.phase_ns[.Devserver], i64(0))
}
