package bridge

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

// Hot-reload guards.
//
// Retry timing (#204 F5): a reload triggered by a non-atomic editor save can
// land on a half-written file and fail. The watcher arms one short retry so
// the editor's finished write is picked up. The timing rule and the
// arm-at-most-once rule are pure predicates, checked without a real clock.
//
// Symlink refusal (#233 M2): hotreload lstat's watched paths to detect
// changes, but the reload itself runs `require("init")` and Lua's loader
// follows symlinks when it opens the file. hotreload_paths_symlink_free
// refuses to reload when a watched runtime path has been swapped for a
// symlink; exercised here against a real symlink on disk.

@(test)
test_hotreload_retry_due_timing :: proc(t: ^testing.T) {
	// Not armed: never due, regardless of elapsed time.
	testing.expect(t, !hotreload_retry_due(false, 0), "disarmed never fires")
	testing.expect(t, !hotreload_retry_due(false, 1000), "disarmed never fires even much later")

	// Armed but before the deadline: not yet.
	testing.expect(t, !hotreload_retry_due(true, 0), "armed but no time passed")
	testing.expect(t, !hotreload_retry_due(true, HOTRELOAD_RETRY_MS - 1), "armed but just under the deadline")

	// Armed and at/after the deadline: due.
	testing.expect(t, hotreload_retry_due(true, HOTRELOAD_RETRY_MS), "exactly at the deadline fires")
	testing.expect(t, hotreload_retry_due(true, HOTRELOAD_RETRY_MS + 5), "past the deadline fires")
}

@(test)
test_hotreload_should_arm_retry :: proc(t: ^testing.T) {
	// Only a fresh mtime change that failed arms a retry.
	testing.expect(t, hotreload_should_arm_retry(.Changed, false), "failed fresh change arms a retry")

	// Everything else leaves it disarmed — crucially, a failed *retry* does
	// not arm another, bounding a broken file to two attempts.
	testing.expect(t, !hotreload_should_arm_retry(.Changed, true), "successful change does not arm")
	testing.expect(t, !hotreload_should_arm_retry(.Retry, false), "failed retry does not re-arm (no loop)")
	testing.expect(t, !hotreload_should_arm_retry(.Retry, true), "successful retry does not arm")
	testing.expect(t, !hotreload_should_arm_retry(.None, false), "no trigger never arms")
	testing.expect(t, !hotreload_should_arm_retry(.None, true), "no trigger never arms")
}

@(test)
test_hotreload_rejects_symlinked_path :: proc(t: ^testing.T) {
	dir := "test_hotreload_symlink_tmp"
	os.make_directory(dir)
	defer os.remove_all(dir)

	real := fmt.tprintf("%s/real.fnl", dir)
	link := fmt.tprintf("%s/link.fnl", dir)

	werr := os.write_entire_file(real, transmute([]u8)string("(local t {}) t"))
	testing.expect(t, werr == os.ERROR_NONE, "wrote the regular watched file")

	// A regular watched file is safe.
	if _, ok := hotreload_paths_symlink_free([]string{real}); !ok {
		testing.fail_now(t, "a regular watched file must be accepted")
	}

	// Create a symlink alongside it and confirm the guard refuses and names it.
	target_c := strings.clone_to_cstring(real, context.temp_allocator)
	link_c := strings.clone_to_cstring(link, context.temp_allocator)
	if errno := linux.symlink(target_c, link_c); errno != .NONE {
		testing.fail_now(t, "could not create test symlink")
	}

	offending, ok := hotreload_paths_symlink_free([]string{real, link})
	testing.expect(t, !ok, "a symlinked watched path must be refused")
	testing.expect_value(t, offending, link)
}

@(test)
test_hotreload_symlink_free_ignores_missing :: proc(t: ^testing.T) {
	// A missing path isn't a symlink; the mtime poll handles absence. The
	// guard must not treat "unreadable" as "unsafe" (that would wedge reload).
	_, ok := hotreload_paths_symlink_free([]string{"does/not/exist.fnl"})
	testing.expect(t, ok, "missing watched path is not treated as a symlink")
}
