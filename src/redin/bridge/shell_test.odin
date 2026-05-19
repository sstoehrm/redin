package bridge

// Regression tests for the shell env allowlist.
//
// When set_shell_env_allowlist is set to a non-nil slice, child processes
// spawned by execute_shell see only the env vars whose KEYs match an
// entry in the allowlist (exact match, case-sensitive). When unset
// (default, nil) the child gets an empty environment — secure-by-default
// per #136 H3. The sentinel "*" entry restores full parent-env passthrough
// (the pre-#136 default) for apps that explicitly opt in.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Tests in this file mutate the package-level shell env allowlist
// (g_shell_env_allowlist). Odin's test runner runs tests in parallel by
// default, so a test that sets the allowlist can race against another
// test that calls execute_shell and depends on the allowlist being unset.
// Acquire this mutex in any test that either calls set_shell_env_allowlist
// or relies on the default-empty-env behaviour.
@(private = "file")
g_test_shell_state_mutex: sync.Mutex

// Deny-by-default env (#136 H3) means tests that spawn children needing
// $PATH to find their cmd (yes, sleep, etc.) must opt in to passthrough.
// The sentinel "*" entry restores full parent-env inheritance.
@(private = "file")
allow_open_shell_env :: proc() {
	set_shell_env_allowlist([]string{"*"})
}

@(test)
test_shell_env_allowlist_filters :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

	// /usr/bin/env exists on Linux/macOS; Linux is the supported platform.
	set_shell_env_allowlist([]string{"PATH"})
	defer set_shell_env_allowlist(nil)

	cmd := make([]string, 1)
	cmd[0] = strings.clone("/usr/bin/env")
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id    = strings.clone("env-1"),
		cmd   = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	// stdout should contain PATH=... but no other typical user env vars.
	testing.expect(t, strings.contains(got.stdout, "PATH="),
		"expected PATH in env output")
	testing.expect(t, !strings.contains(got.stdout, "HOME="),
		"expected HOME stripped by allowlist")
}

@(test)
test_shell_env_allowlist_unset_is_empty :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

	// Default (nil allowlist) must mean empty env after #136 H3.
	set_shell_env_allowlist(nil)

	cmd := make([]string, 1)
	cmd[0] = strings.clone("/usr/bin/env")
	defer { for s in cmd do delete(s); delete(cmd) }
	req := Shell_Request{
		id    = strings.clone("env-empty"),
		cmd   = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}
	// /usr/bin/env should print nothing — no PATH, no HOME, no anything.
	testing.expect(t, !strings.contains(got.stdout, "PATH="),
		fmt.tprintf("expected empty env (deny-by-default), got %q", got.stdout))
	testing.expect(t, !strings.contains(got.stdout, "HOME="),
		fmt.tprintf("expected empty env (deny-by-default), got %q", got.stdout))
}

@(test)
test_shell_env_allowlist_wildcard_is_full_passthrough :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

	// The sentinel "*" entry is the explicit opt-out of deny-by-default.
	set_shell_env_allowlist([]string{"*"})
	defer set_shell_env_allowlist(nil)

	cmd := make([]string, 1)
	cmd[0] = strings.clone("/usr/bin/env")
	defer { for s in cmd do delete(s); delete(cmd) }
	req := Shell_Request{
		id    = strings.clone("env-star"),
		cmd   = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}
	// PATH is reliably present in the test runner's env.
	testing.expect(t, strings.contains(got.stdout, "PATH="),
		"expected PATH= in wildcard-passthrough env output")
}

@(test)
test_shell_output_cap_kills_child :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)
	allow_open_shell_env()
	defer set_shell_env_allowlist(nil)

	// `yes` runs forever; with a 1 MiB cap it should be killed quickly.
	cmd := make([]string, 1)
	cmd[0] = strings.clone("yes")
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id = strings.clone("cap-1"),
		cmd = cmd,
		stdin = strings.clone(""),
		max_output_bytes = 1 * 1024 * 1024,
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	testing.expect_value(t, got.exit_code, -1)
	testing.expect(t, strings.contains(got.error_msg, "exceeded"),
		fmt.tprintf("expected 'exceeded' in error_msg, got %q", got.error_msg))
	testing.expect_value(t, len(got.stdout), 0)
	testing.expect_value(t, len(got.stderr), 0)
}

@(test)
test_shell_timeout_kills_child :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)
	allow_open_shell_env()
	defer set_shell_env_allowlist(nil)

	// `sleep 60` should be killed by a 200 ms timeout.
	cmd := make([]string, 2)
	cmd[0] = strings.clone("sleep")
	cmd[1] = strings.clone("60")
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id = strings.clone("to-1"),
		cmd = cmd,
		stdin = strings.clone(""),
		timeout_ms = 200,
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	testing.expect_value(t, got.exit_code, -1)
	testing.expect(t, strings.contains(got.error_msg, "timeout"),
		fmt.tprintf("expected 'timeout' in error_msg, got %q", got.error_msg))
}
