package bridge

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"

SHELL_DEFAULT_MAX_OUTPUT :: 16 * 1024 * 1024 // 16 MiB

Shell_Request :: struct {
	id:               string,
	cmd:              []string,
	stdin:            string,
	max_output_bytes: int,
}

Shell_Response :: struct {
	id:        string,
	stdout:    string,
	stderr:    string,
	exit_code: int,
	error_msg: string,
}

Shell_Client :: struct {
	results:       [dynamic]Shell_Response,
	results_mutex: sync.Mutex,
}

shell_client_init :: proc(sc: ^Shell_Client) {
}

shell_client_destroy :: proc(sc: ^Shell_Client) {
	sync.lock(&sc.results_mutex)
	for &r in sc.results {
		shell_response_destroy(&r)
	}
	delete(sc.results)
	sync.unlock(&sc.results_mutex)
}

shell_response_destroy :: proc(r: ^Shell_Response) {
	delete(r.id)
	delete(r.stdout)
	delete(r.stderr)
	delete(r.error_msg)
}

Shell_Thread_Data :: struct {
	client:  ^Shell_Client,
	request: Shell_Request,
}

shell_client_request :: proc(sc: ^Shell_Client, req: Shell_Request) {
	data := new(Shell_Thread_Data)
	data.client = sc
	data.request = req
	thread.create_and_start_with_data(data, shell_thread_proc, self_cleanup = true)
}

shell_client_poll :: proc(sc: ^Shell_Client, results: ^[dynamic]Shell_Response) {
	sync.lock(&sc.results_mutex)
	defer sync.unlock(&sc.results_mutex)
	for &r in sc.results {
		append(results, r)
	}
	clear(&sc.results)
}

@(private = "file")
shell_thread_proc :: proc(raw_data_ptr: rawptr) {
	data := cast(^Shell_Thread_Data)raw_data_ptr
	response := execute_shell(data.request)

	sync.lock(&data.client.results_mutex)
	append(&data.client.results, response)
	sync.unlock(&data.client.results_mutex)

	shell_request_destroy(&data.request)
	free(data)
}

@(private = "file")
shell_request_destroy :: proc(req: ^Shell_Request) {
	delete(req.id)
	delete(req.stdin)
	for s in req.cmd {
		delete(s)
	}
	delete(req.cmd)
}

execute_shell :: proc(req: Shell_Request) -> Shell_Response {
	response: Shell_Response
	response.id = strings.clone(req.id)

	if len(req.cmd) == 0 {
		response.error_msg = strings.clone("Empty command")
		response.exit_code = -1
		return response
	}

	// Combined stdout+stderr cap. 0 / negative means "use default 16 MiB".
	output_cap := req.max_output_bytes
	if output_cap <= 0 do output_cap = SHELL_DEFAULT_MAX_OUTPUT

	// Create pipes for stdout and stderr
	stdout_r, stdout_w, stdout_err := os.pipe()
	if stdout_err != nil {
		response.error_msg = fmt.aprintf("Failed to create stdout pipe: %v", stdout_err)
		response.exit_code = -1
		return response
	}
	defer os.close(stdout_r)

	stderr_r, stderr_w, stderr_err := os.pipe()
	if stderr_err != nil {
		os.close(stdout_w)
		response.error_msg = fmt.aprintf("Failed to create stderr pipe: %v", stderr_err)
		response.exit_code = -1
		return response
	}
	defer os.close(stderr_r)

	// Create stdin pipe if we have input
	stdin_r: ^os.File = nil
	stdin_w: ^os.File = nil
	if len(req.stdin) > 0 {
		r, w, err := os.pipe()
		if err != nil {
			os.close(stdout_w)
			os.close(stderr_w)
			response.error_msg = fmt.aprintf("Failed to create stdin pipe: %v", err)
			response.exit_code = -1
			return response
		}
		stdin_r = r
		stdin_w = w
	}

	// Apply the env allowlist (issue #99 M3). When the allowlist is unset,
	// shell_env_filtered returns nil — and Process_Desc.env = nil is the
	// documented "inherit current process' environment" sentinel (see
	// core/os/process.odin's Process_Desc docstring), preserving the
	// historical full-passthrough behaviour.
	//
	// When set, shell_env_filtered allocates each entry + the slice via
	// runtime.heap_allocator(); we free both after process_start, since
	// process_start (Linux execve) copies the env into the child image.
	filtered_env := shell_env_filtered()
	defer if filtered_env != nil {
		heap := runtime.heap_allocator()
		for s in filtered_env do delete(s, heap)
		delete(filtered_env, heap)
	}

	// Start process
	desc := os.Process_Desc {
		command = req.cmd,
		stdout  = stdout_w,
		stderr  = stderr_w,
		stdin   = stdin_r,
		env     = filtered_env, // nil = inherit parent env (default)
	}

	process, start_err := os.process_start(desc)
	// Close write ends of stdout/stderr so reads detect EOF
	os.close(stdout_w)
	os.close(stderr_w)
	// Close read end of stdin (process owns it now)
	if stdin_r != nil do os.close(stdin_r)

	if start_err != nil {
		if stdin_w != nil do os.close(stdin_w)
		response.error_msg = fmt.aprintf("Failed to start process: %v", start_err)
		response.exit_code = -1
		return response
	}

	// Write stdin
	if stdin_w != nil {
		os.write(stdin_w, transmute([]u8)req.stdin)
		os.close(stdin_w)
	}

	// Read stdout and stderr
	stdout_buf: [dynamic]u8
	stderr_buf: [dynamic]u8
	defer delete(stdout_buf)
	defer delete(stderr_buf)

	read_buf: [4096]u8
	stdout_done, stderr_done: bool

	// Use linux.poll to multiplex stdout + stderr reads. The previous
	// blocking-read approach (os.read on each pipe in turn) deadlocked
	// for stderr-quiet long-running children: e.g. `yes` writes only
	// to stdout, so the stderr read blocked indefinitely while the
	// stdout buffer grew unbounded — the cap check at the bottom of
	// the loop body could never fire. With poll, we only read the
	// pipe(s) that actually have data ready (or have been closed) and
	// re-check the cap each iteration.
	//
	// 50 ms timeout balances responsiveness vs. CPU. On overflow, kill
	// the child, clear partial buffers, and surface a -1 exit code with
	// a descriptive error_msg (issue #99 M2 A). Subsequent reads would
	// return EOF as the kernel closes the (now-orphaned) pipe ends, but
	// we break out immediately and reap the child below.
	killed := false
	for !stdout_done || !stderr_done {
		fds: [2]linux.Poll_Fd
		n_fds := 0
		stdout_idx := -1
		stderr_idx := -1
		if !stdout_done {
			fds[n_fds] = linux.Poll_Fd {
				fd     = linux.Fd(os.fd(stdout_r)),
				events = {.IN},
			}
			stdout_idx = n_fds
			n_fds += 1
		}
		if !stderr_done {
			fds[n_fds] = linux.Poll_Fd {
				fd     = linux.Fd(os.fd(stderr_r)),
				events = {.IN},
			}
			stderr_idx = n_fds
			n_fds += 1
		}

		n_ready, perr := linux.poll(fds[:n_fds], 50)
		if perr != .NONE {
			// poll error (e.g. EINTR) — bail out cleanly; the cap
			// or wait below will surface any final state.
			stdout_done = true
			stderr_done = true
			break
		}

		if n_ready > 0 {
			if stdout_idx >= 0 &&
			   (.IN in fds[stdout_idx].revents || .HUP in fds[stdout_idx].revents) {
				n, err := os.read(stdout_r, read_buf[:])
				if err != nil || n <= 0 {
					stdout_done = true
				} else {
					append(&stdout_buf, ..read_buf[:n])
				}
			}
			if stderr_idx >= 0 &&
			   (.IN in fds[stderr_idx].revents || .HUP in fds[stderr_idx].revents) {
				n, err := os.read(stderr_r, read_buf[:])
				if err != nil || n <= 0 {
					stderr_done = true
				} else {
					append(&stderr_buf, ..read_buf[:n])
				}
			}
		}

		if len(stdout_buf) + len(stderr_buf) > output_cap {
			_ = os.process_kill(process)
			clear(&stdout_buf)
			clear(&stderr_buf)
			response.exit_code = -1
			response.error_msg = fmt.aprintf(
				"shell output exceeded %d MiB cap",
				output_cap / (1024 * 1024),
			)
			killed = true
			break
		}
	}

	if killed {
		// Reap the child to avoid a zombie. The exit_code from a SIGKILL'd
		// process isn't useful here — we already set it to -1 above to
		// signal "cap exceeded" distinctly from a normal non-zero exit.
		_, _ = os.process_wait(process)
		return response
	}

	// Wait for process
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		response.error_msg = fmt.aprintf("Failed to wait for process: %v", wait_err)
		response.exit_code = -1
	} else {
		response.exit_code = state.exit_code
	}

	response.stdout = strings.clone(string(stdout_buf[:]))
	response.stderr = strings.clone(string(stderr_buf[:]))

	return response
}
