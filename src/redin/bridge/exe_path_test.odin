package bridge

import "core:testing"

@(test)
test_path_parent_dir_relative :: proc(t: ^testing.T) {
	dir, has_sep := path_parent_dir("build/redin")
	testing.expect(t, has_sep, "relative path has a separator")
	testing.expect_value(t, dir, "build")
}

@(test)
test_path_parent_dir_absolute :: proc(t: ^testing.T) {
	dir, has_sep := path_parent_dir("/usr/local/bin/redin")
	testing.expect(t, has_sep)
	testing.expect_value(t, dir, "/usr/local/bin")
}

@(test)
test_path_parent_dir_root_anchored :: proc(t: ^testing.T) {
	// A binary directly under root: the parent dir is the root, not "".
	dir, has_sep := path_parent_dir("/redin")
	testing.expect(t, has_sep)
	testing.expect_value(t, dir, "/")
}

@(test)
test_path_parent_dir_bare_name :: proc(t: ^testing.T) {
	// The security-relevant case (#233 H1): a $PATH-resolved bare command
	// name has no separator, so has_sep must be false so the caller falls
	// back to /proc/self/exe instead of defaulting exe_dir to ".".
	dir, has_sep := path_parent_dir("redin")
	testing.expect(t, !has_sep, "bare name must report no separator")
	testing.expect_value(t, dir, "")
}

@(test)
test_path_parent_dir_backslash :: proc(t: ^testing.T) {
	dir, has_sep := path_parent_dir("C:\\tools\\redin.exe")
	testing.expect(t, has_sep)
	testing.expect_value(t, dir, "C:\\tools")
}

@(test)
test_path_parent_dir_empty :: proc(t: ^testing.T) {
	dir, has_sep := path_parent_dir("")
	testing.expect(t, !has_sep)
	testing.expect_value(t, dir, "")
}
