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
	// #284 I2: lstat, not stat — same no-symlink policy as the hot-reload
	// watcher (#162 L1, #233 M2). A symlink named like the marker in a
	// foreign CWD must not flip on cwd-relative lookups and hot reload.
	// lstat alone is not enough (the link itself "exists"), so the
	// marker must also be a regular file.
	fi, err := os.lstat(marker_path, context.temp_allocator)
	return err == os.ERROR_NONE && fi.type == .Regular
}
