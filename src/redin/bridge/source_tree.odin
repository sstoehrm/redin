package bridge

import "core:os"

// is_redin_source_tree reports whether the current working directory
// looks like the redin source tree. The marker `src/cmd/redin/main.odin`
// is unique to this repo — no chance a user app or shared workspace
// has a `src/cmd/redin/` directory by accident. Issue #129 H6.
//
// When false, the bridge skips cwd-relative entries in fennel.path /
// package.path and disables hot reload, so a poisoned
// `./src/runtime/init.fnl` next to the user's working directory is
// not loaded.
is_redin_source_tree :: proc() -> bool {
	return is_redin_source_tree_at("src/cmd/redin/main.odin")
}

@(private = "package")
is_redin_source_tree_at :: proc(marker_path: string) -> bool {
	_, err := os.stat(marker_path, context.temp_allocator)
	return err == os.ERROR_NONE
}
