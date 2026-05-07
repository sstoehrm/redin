package bridge

// Regression tests for issue #99 M3: opt-in shell env allowlist.
//
// When set_shell_env_allowlist is set to a non-nil slice, child processes
// spawned by execute_shell see only the env vars whose KEYs match an
// entry in the allowlist (exact match, case-sensitive). When unset
// (default, nil), children inherit the full parent env — preserving
// the historical behaviour for apps that shell out to credential-aware
// tools like `gh`, `aws`, or `git`.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

// Tests in this file mutate the package-level shell env allowlist
// (g_shell_env_allowlist). Odin's test runner runs tests in parallel by
// default, so a test that sets the allowlist can race against another
// test that calls execute_shell and depends on the allowlist being unset.
// Acquire this mutex in any test that either calls set_shell_env_allowlist
// or relies on the default-passthrough behaviour.
@(private = "file")
g_test_shell_state_mutex: sync.Mutex

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
test_shell_env_allowlist_unset_full_passthrough :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

	set_shell_env_allowlist(nil)

	cmd := make([]string, 1)
	cmd[0] = strings.clone("/usr/bin/env")
	defer { for s in cmd do delete(s); delete(cmd) }
	req := Shell_Request{
		id    = strings.clone("env-2"),
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
		"expected PATH= in default-passthrough env output")
}

@(test)
test_shell_output_cap_kills_child :: proc(t: ^testing.T) {
	sync.lock(&g_test_shell_state_mutex)
	defer sync.unlock(&g_test_shell_state_mutex)

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
