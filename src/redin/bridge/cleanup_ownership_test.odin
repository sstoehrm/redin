package bridge

// #217 L1: the signal handler and the normal shutdown path previously unlinked
// .redin-port / .redin-token unconditionally. Two redin instances sharing a
// CWD clobber each other's files at startup, so the live owner is whoever
// wrote last; a crashing instance must NOT remove a file a *different* live
// instance owns. unlink_if_matches only unlinks when the on-disk content
// equals the value we recorded at write time.

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

@(test)
test_unlink_if_matches_removes_on_match :: proc(t: ^testing.T) {
	path := "test_redin_l1_match.tmp"
	testing.expect(t, os.write_entire_file(path, "our-token-abc") == nil,
		"setup: write temp file")
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	unlink_if_matches(cpath, transmute([]u8)string("our-token-abc"))

	defer if os.exists(path) do os.remove(path)
	testing.expect(t, !os.exists(path), "our own file must be removed on match")
}

@(test)
test_unlink_if_matches_keeps_on_mismatch :: proc(t: ^testing.T) {
	path := "test_redin_l1_mismatch.tmp"
	testing.expect(t, os.write_entire_file(path, "other-instance-token") == nil,
		"setup: write temp file")
	defer os.remove(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	unlink_if_matches(cpath, transmute([]u8)string("our-token"))

	testing.expect(t, os.exists(path),
		"a co-located live instance's file must be left intact on content mismatch")
}

@(test)
test_unlink_if_matches_keeps_on_prefix :: proc(t: ^testing.T) {
	// On-disk content shares a prefix with our value but is longer. A prefix
	// match must not trigger unlink — lengths must be equal.
	path := "test_redin_l1_prefix.tmp"
	testing.expect(t, os.write_entire_file(path, "abc-extra") == nil,
		"setup: write temp file")
	defer os.remove(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	unlink_if_matches(cpath, transmute([]u8)string("abc"))

	testing.expect(t, os.exists(path), "prefix-only match must not unlink")
}

// #284 L1: O_NOFOLLOW stops symlinks but not FIFOs. A blocking open on a
// writer-less FIFO substituted into CWD would hang shutdown (and the
// re-raise in cleanup_on_signal). The helper must return promptly and
// leave anything that is not a regular file alone.
@(test)
test_unlink_if_matches_ignores_fifo :: proc(t: ^testing.T) {
	path := "test_redin_284_fifo.tmp"
	os.remove(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	merr := linux.mknod(cpath, {.IFIFO, .IRUSR, .IWUSR}, 0)
	testing.expectf(t, merr == .NONE, "setup: mknod FIFO failed (%v)", merr)
	defer os.remove(path)

	// Would block forever without O_NONBLOCK (no writer on the FIFO).
	unlink_if_matches(cpath, transmute([]u8)string("our-token"))

	testing.expect(t, os.exists(path), "a FIFO must never be unlinked")
}

@(test)
test_unlink_if_matches_ignores_directory :: proc(t: ^testing.T) {
	path := "test_redin_284_dir.tmp"
	os.remove(path)
	testing.expect(t, os.make_directory(path) == nil, "setup: mkdir")
	defer os.remove(path)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)

	unlink_if_matches(cpath, transmute([]u8)string("our-token"))

	testing.expect(t, os.exists(path), "a directory must never be unlinked")
}
