package bridge

// Tests for the redin source-tree marker introduced for issue #129 H6.
// The marker decides whether the bridge may use cwd-relative
// fennel.path / package.path entries and watch cwd-relative files for
// hot reload. The presence of `src/cmd/redin/main.odin` is the marker.

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

@(test)
test_is_redin_source_tree_at_present :: proc(t: ^testing.T) {
	// `odin test` runs from the redin source root; the canonical marker
	// is therefore present.
	testing.expect(
		t,
		is_redin_source_tree_at("src/cmd/redin/main.odin"),
		"expected marker to exist when running from redin source root",
	)
}

@(test)
test_is_redin_source_tree_at_absent :: proc(t: ^testing.T) {
	// A path no test fixture creates returns false.
	testing.expect(
		t,
		!is_redin_source_tree_at("does/not/exist/anywhere/marker.txt"),
		"expected absent marker to return false",
	)
}

// #284 I2: the marker check must not follow symlinks, matching the
// lstat policy of the hot-reload watcher (#162 L1, #233 M2). A symlink
// named like the marker in a foreign CWD must not enable cwd-relative
// module lookups and hot reload.
@(test)
test_is_redin_source_tree_at_ignores_symlink :: proc(t: ^testing.T) {
	dir := "test_redin_284_marker.tmp"
	link := "test_redin_284_marker.tmp/main.odin"
	os.remove(link)
	os.remove(dir)
	testing.expect(t, os.make_directory(dir) == nil, "setup: mkdir")
	defer os.remove(dir)
	// Point at a file that definitely exists so a stat-based check would
	// succeed through the link.
	cl := strings.clone_to_cstring(link, context.temp_allocator)
	serr := linux.symlink("../src/cmd/redin/main.odin", cl)
	testing.expectf(t, serr == .NONE, "setup: symlink failed (%v)", serr)
	defer os.remove(link)

	testing.expect(
		t,
		!is_redin_source_tree_at(link),
		"a symlinked marker must not count as the redin source tree",
	)
}
