package bridge

// #233 M4: the lexical validate_font_path confines a font path to the cwd
// subtree only textually — a symlink inside that subtree can still resolve
// out of it. font_path_escapes_cwd canonicalizes the path and rejects a real
// target that leaves the working directory. These tests exercise it against
// real files and symlinks on disk.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

@(test)
test_font_path_inside_cwd_ok :: proc(t: ^testing.T) {
	dir := "test_font_escape_tmp"
	os.make_directory(dir)
	defer os.remove_all(dir)

	real := fmt.tprintf("%s/real.ttf", dir)
	werr := os.write_entire_file(real, transmute([]u8)string("not-a-real-font"))
	testing.expect(t, werr == os.ERROR_NONE, "wrote the in-tree font file")

	// A real file under cwd does not escape.
	testing.expect(t, !font_path_escapes_cwd(real), "in-tree font must be allowed")
}

@(test)
test_font_path_missing_is_allowed :: proc(t: ^testing.T) {
	// A non-existent path can't be canonicalized; LoadFont will just fail.
	// The guard must not reject it (that would change existing behavior).
	testing.expect(t, !font_path_escapes_cwd("test_font_escape_tmp/does-not-exist.ttf"))
}

@(test)
test_font_path_symlink_escape_rejected :: proc(t: ^testing.T) {
	dir := "test_font_escape_tmp2"
	os.make_directory(dir)
	defer os.remove_all(dir)

	// An escape target that exists OUTSIDE the working directory.
	tmpdir := os.get_env("TMPDIR", context.temp_allocator)
	if tmpdir == "" do tmpdir = "/tmp"
	target := fmt.tprintf("%s/redin_font_escape_target.ttf", tmpdir)
	werr := os.write_entire_file(target, transmute([]u8)string("outside-cwd"))
	testing.expect(t, werr == os.ERROR_NONE, "wrote the out-of-tree target")
	defer os.remove(target)

	// A symlink inside cwd pointing at it: lexically clean, but escapes.
	link := fmt.tprintf("%s/escape.ttf", dir)
	target_c := strings.clone_to_cstring(target, context.temp_allocator)
	link_c := strings.clone_to_cstring(link, context.temp_allocator)
	if errno := linux.symlink(target_c, link_c); errno != .NONE {
		testing.fail_now(t, "could not create escaping symlink")
	}

	// The lexical guard passes it (no "..", relative), but the resolved-path
	// guard must catch the escape.
	testing.expect(t, validate_font_path(link), "symlink path is lexically clean")
	testing.expect(t, font_path_escapes_cwd(link), "symlink escaping cwd must be rejected")
}

@(test)
test_font_path_symlink_inside_ok :: proc(t: ^testing.T) {
	dir := "test_font_escape_tmp3"
	os.make_directory(dir)
	defer os.remove_all(dir)

	real := fmt.tprintf("%s/real.ttf", dir)
	werr := os.write_entire_file(real, transmute([]u8)string("in-tree-target"))
	testing.expect(t, werr == os.ERROR_NONE)

	// A symlink that stays within cwd is fine.
	cwd, _ := os.get_working_directory(context.temp_allocator)
	abs_real := fmt.tprintf("%s/%s", cwd, real)
	link := fmt.tprintf("%s/link.ttf", dir)
	target_c := strings.clone_to_cstring(abs_real, context.temp_allocator)
	link_c := strings.clone_to_cstring(link, context.temp_allocator)
	if errno := linux.symlink(target_c, link_c); errno != .NONE {
		testing.fail_now(t, "could not create in-tree symlink")
	}
	testing.expect(t, !font_path_escapes_cwd(link), "symlink resolving inside cwd is allowed")
}
