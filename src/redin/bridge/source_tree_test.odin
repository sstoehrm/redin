package bridge

// Tests for the redin source-tree marker introduced for issue #129 H6.
// The marker decides whether the bridge may use cwd-relative
// fennel.path / package.path entries and watch cwd-relative files for
// hot reload. The presence of `src/cmd/redin/main.odin` is the marker.

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
