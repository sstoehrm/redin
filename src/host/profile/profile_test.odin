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
