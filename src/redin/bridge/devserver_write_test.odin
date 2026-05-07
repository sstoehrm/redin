package bridge

// Regression tests for issue #78 finding M1: the dev server's writes to
// .redin-port and .redin-token must not follow symlinks. Without
// O_NOFOLLOW, an attacker (or a stale symlink in CWD) could redirect
// the write to an arbitrary file owned by the user (e.g. ~/.ssh/authorized_keys).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

@(private = "file")
make_tmp_path :: proc(suffix: string) -> string {
	dir, derr := os.temp_directory(context.temp_allocator)
	if derr != nil {
		dir = "/tmp"
	}
	pid := linux.getpid()
	return fmt.aprintf("%s/redin_test_%d_%s", dir, i32(pid), suffix)
}

@(private = "file")
read_all :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return "", false
	return string(data), true
}

@(test)
test_write_private_no_follow_creates_new_file :: proc(t: ^testing.T) {
	path := make_tmp_path("new")
	defer delete(path)
	defer os.remove(path)

	payload := "hello"
	testing.expect(t, write_private_no_follow(path, transmute([]u8)payload))

	got, ok := read_all(path)
	defer if ok do delete(got)
	testing.expect(t, ok, "expected file to be readable after write")
	testing.expect_value(t, got, payload)
}

@(test)
test_write_private_no_follow_refuses_symlink :: proc(t: ^testing.T) {
	target := make_tmp_path("symlink_target")
	link   := make_tmp_path("symlink_link")
	defer delete(target)
	defer delete(link)
	defer os.remove(target)
	defer os.remove(link)

	// Plant a regular file with sentinel content, then a symlink
	// pointing at it. If the helper follows the link, the sentinel
	// content gets overwritten — the bug under test.
	sentinel := "PROTECTED\n"
	_ = os.write_entire_file(target, transmute([]u8)sentinel)

	ctarget := strings.clone_to_cstring(target, context.temp_allocator)
	clink   := strings.clone_to_cstring(link,   context.temp_allocator)
	if errno := linux.symlink(ctarget, clink); errno != .NONE {
		testing.fail_now(t, fmt.tprintf("symlink setup failed: %v", errno))
	}

	payload := "ATTACKER_OVERWRITE"
	ok := write_private_no_follow(link, transmute([]u8)payload)
	testing.expect(t, !ok, "write_private_no_follow must refuse to write through a symlink")

	got, read_ok := read_all(target)
	defer if read_ok do delete(got)
	testing.expect(t, read_ok, "symlink target should still be readable")
	testing.expect_value(t, got, sentinel)
}

// Regression test for issue #99 finding L2: the dev server must abort
// startup if .redin-port or .redin-token cannot be written. Previously
// it logged a warning and kept running, which produced silent 401
// responses on every request because clients authenticate by reading
// .redin-token from disk.
//
// Forces a write failure by planting a directory at .redin-token in
// the test's CWD: write_private_no_follow opens with O_NOFOLLOW|O_EXCL,
// gets EEXIST, lstats and rejects anything that isn't a regular file.
@(test)
test_write_port_and_token_aborts_on_failure :: proc(t: ^testing.T) {
	original_cwd, cwd_err := os.getwd(context.temp_allocator)
	if cwd_err != nil {
		testing.fail_now(t, fmt.tprintf("getwd failed: %v", cwd_err))
	}
	defer os.chdir(original_cwd)

	tmp_dir := make_tmp_path("write_abort_dir")
	defer delete(tmp_dir)
	if mkerr := os.make_directory(tmp_dir); mkerr != nil {
		testing.fail_now(t, fmt.tprintf("make_directory(%s) failed: %v", tmp_dir, mkerr))
	}
	defer os.remove(tmp_dir)

	if cherr := os.chdir(tmp_dir); cherr != nil {
		testing.fail_now(t, fmt.tprintf("chdir(%s) failed: %v", tmp_dir, cherr))
	}

	// Plant a directory at TOKEN_FILE so write_private_no_follow refuses it.
	// PORT_FILE is left unplanted so the helper succeeds at writing it
	// first, then fails on the token write — exercising the cleanup path.
	if mkerr := os.make_directory(TOKEN_FILE); mkerr != nil {
		testing.fail_now(t, fmt.tprintf("planting directory at %s failed: %v", TOKEN_FILE, mkerr))
	}
	defer os.remove(TOKEN_FILE)
	defer os.remove(PORT_FILE) // helper writes this before failing on token

	ds := Dev_Server{
		running    = true,
		auth_token = "test_token_value",
	}

	ok := write_port_and_token_files(&ds, 9999)
	testing.expect(t, !ok, "write_port_and_token_files must return false when token write fails")
	testing.expect(t, !ds.running, "ds.running must be cleared after a write failure")

	// .redin-port must be cleaned up so it doesn't advertise a server
	// that never finished standing up.
	if _, stat_err := os.stat(PORT_FILE, context.temp_allocator); stat_err == nil {
		testing.fail(t)
		fmt.println("PORT_FILE was not cleaned up after token write failure")
	}
}

@(test)
test_write_private_no_follow_replaces_stale_regular_file :: proc(t: ^testing.T) {
	// A previous dev run that crashed leaves .redin-token behind as a
	// regular file with mode 0600. The next run must be able to replace
	// it (otherwise dev mode breaks after any crash). The replacement
	// must NOT preserve any prior content.
	path := make_tmp_path("stale")
	defer delete(path)
	defer os.remove(path)

	stale := "leftover_from_previous_run"
	_ = os.write_entire_file(path, transmute([]u8)stale)

	fresh := "new_token_value"
	testing.expect(t, write_private_no_follow(path, transmute([]u8)fresh))

	got, ok := read_all(path)
	defer if ok do delete(got)
	testing.expect(t, ok)
	testing.expect_value(t, got, fresh)
}
