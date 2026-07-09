package bridge

// #233 M2: hotreload lstat's watched paths to detect changes, but the reload
// itself runs `require("init")` and Lua's loader follows symlinks when it
// opens the file. hotreload_paths_symlink_free is the guard that refuses to
// reload when a watched runtime path has been swapped for a symlink. This
// test exercises it against a real symlink on disk.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

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
