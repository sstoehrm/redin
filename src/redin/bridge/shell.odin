package bridge

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"

SHELL_DEFAULT_MAX_OUTPUT :: 16 * 1024 * 1024 // 16 MiB
SHELL_DEFAULT_TIMEOUT_MS :: 30_000
SHELL_MAX_STDIN :: 64 * 1024 * 1024 // 64 MiB cap on child stdin (#167)

// #167: SIGPIPE's default disposition terminates the whole process. redin
// does pipe I/O (child stdin) and socket I/O (http client, dev server), any
// of which can write to a peer that closed its read end. Ignore SIGPIPE
// process-wide once and handle EPIPE via return values instead. Installed
// from shell_client_init (bridge init); idempotent.
@(private = "file")
g_sigpipe_ignored: bool

ignore_sigpipe :: proc() {
	if g_sigpipe_ignored do return
	g_sigpipe_ignored = true
	sa := linux.Sig_Action(rawptr) {
		handler = transmute(linux.Sig_Handler_Fn)(uintptr(linux.Sig_Action_Special.SIG_IGN)),
	}
	linux.rt_sigaction(.SIGPIPE, &sa, (^linux.Sig_Action(rawptr))(nil))
}

Shell_Request :: struct {
	id:               string,
	cmd:              []string,
	stdin:            string,
	max_output_bytes: int,
	timeout_ms:       int,
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
	// #166: shutdown drain, mirroring Http_Client. Workers run on detached
	// threads and append into `results`; freeing it while one is still in
	// flight is a use-after-free. `workers_alive` counts workers holding a
	// pointer into this struct (destroy waits for it to reach 0 before
	// freeing); `processes` lets destroy kill in-flight children to bound
	// that wait. Both `destroying` and `workers_alive` are accessed
	// atomically.
	destroying:    bool,
	workers_alive: i32,
	processes:     map[string]os.Process,
	procs_mutex:   sync.Mutex,
}

shell_client_init :: proc(sc: ^Shell_Client) {
	ignore_sigpipe()
}

shell_client_destroy :: proc(sc: ^Shell_Client) {
	// Signal shutdown, then kill any in-flight children so their workers
	// unblock fast, then wait (bounded) for every worker to finish before
	// freeing state they would otherwise touch (#166).
	sync.atomic_store(&sc.destroying, true)

	sync.lock(&sc.procs_mutex)
	for _, p in sc.processes {
		_ = os.process_kill(p)
	}
	sync.unlock(&sc.procs_mutex)

	deadline := time.time_add(time.now(), 3 * time.Second)
	for {
		if sync.atomic_load(&sc.workers_alive) == 0 do break
		if time.diff(time.now(), deadline) <= 0 do break
		time.sleep(10 * time.Millisecond)
	}

	leaked := sync.atomic_load(&sc.workers_alive)
	if leaked == 0 {
		sync.lock(&sc.results_mutex)
		for &r in sc.results {
			shell_response_destroy(&r)
		}
		delete(sc.results)
		sync.unlock(&sc.results_mutex)

		sync.lock(&sc.procs_mutex)
		delete(sc.processes)
		sync.unlock(&sc.procs_mutex)
	} else {
		// A worker may still append to results / touch the maps; leak them
		// deliberately rather than risk a use-after-free.
		fmt.eprintfln("redin: warning: %d shell worker(s) still in flight at shutdown", leaked)
	}
}

shell_response_destroy :: proc(r: ^Shell_Response) {
	delete(r.id)
	delete(r.stdout)
	delete(r.stderr)
	delete(r.error_msg)
}

// Append a synthesized failure result for a request rejected before it is
// ever spawned (e.g. a malformed :cmd, #172), so the matching on-error
// handler still fires with a clear message instead of the request silently
// misbehaving.
shell_emit_error :: proc(sc: ^Shell_Client, id: string, msg: string) {
	r := Shell_Response {
		id        = strings.clone(id),
		exit_code = -1,
		error_msg = strings.clone(msg),
	}
	sync.lock(&sc.results_mutex)
	append(&sc.results, r)
	sync.unlock(&sc.results_mutex)
}

Shell_Thread_Data :: struct {
	client:  ^Shell_Client,
	request: Shell_Request,
}

shell_client_request :: proc(sc: ^Shell_Client, req: Shell_Request) {
	data := new(Shell_Thread_Data)
	data.client = sc
	data.request = req
	// Count this worker before it starts so shell_client_destroy can wait
	// for it (#166). The worker decrements last, after its final access.
	sync.atomic_add(&sc.workers_alive, 1)
	// Pass the caller's context so the worker allocates Shell_Response
	// strings (and frees the request + thread data) with the same allocator
	// the main thread uses on its side of the handoff. Without this, the
	// worker runs under `runtime.default_context()` (heap), and the main
	// thread's tracking allocator (REDIN_TRACK_MEM) hits a bad-free
	// assertion -> SIGILL when it frees the response (#214). Mirrors
	// Http_Client; core:thread swaps in a per-thread temp allocator.
	thread.create_and_start_with_data(data, shell_thread_proc, init_context = context, self_cleanup = true)
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
	response := execute_shell(data.request, data.client)

	sync.lock(&data.client.results_mutex)
	if !sync.atomic_load(&data.client.destroying) {
		append(&data.client.results, response)
	} else {
		// Client is being torn down; don't append into state it may free.
		shell_response_destroy(&response)
	}
	sync.unlock(&data.client.results_mutex)

	shell_request_destroy(&data.request)
	client := data.client
	free(data)
	// Decrement LAST so shell_client_destroy doesn't observe 0 and free the
	// client while we still hold a pointer into it (#166).
	sync.atomic_sub(&client.workers_alive, 1)
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

execute_shell :: proc(req: Shell_Request, client: ^Shell_Client = nil) -> Shell_Response {
	response: Shell_Response
	response.id = strings.clone(req.id)

	if len(req.cmd) == 0 {
		response.error_msg = strings.clone("Empty command")
		response.exit_code = -1
		return response
	}

	// #167: bound the cloned stdin so a pathological :stdin can't pin
	// unbounded memory; the poll-loop writer below handles any size safely,
	// this is just a documented ceiling.
	if len(req.stdin) > SHELL_MAX_STDIN {
		response.error_msg = fmt.aprintf("shell stdin exceeds %d MiB cap", SHELL_MAX_STDIN / (1024 * 1024))
		response.exit_code = -1
		return response
	}

	// Combined stdout+stderr cap. 0 / negative means "use default 16 MiB".
	output_cap := req.max_output_bytes
	if output_cap <= 0 do output_cap = SHELL_DEFAULT_MAX_OUTPUT

	// Per-call wall-clock timeout (issue #99 M2 B). 0 / negative means
	// "use default 30 000 ms". The deadline is checked once per poll
	// iteration below; with a 50 ms poll tick, deadline responsiveness
	// is bounded by ~50 ms past the requested timeout.
	timeout_ms := req.timeout_ms
	if timeout_ms <= 0 do timeout_ms = SHELL_DEFAULT_TIMEOUT_MS
	// Note: deadline includes process_start latency. Tight (<100 ms) timeouts
	// may fire before exec returns. Negligible for the 30 s default.
	deadline := time.time_add(time.now(), time.Duration(timeout_ms) * time.Millisecond)

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

	// Apply the env allowlist (#136 H3). Deny-by-default:
	//   - Allowlist unset/empty → child gets an empty env. We pass a
	//     non-nil zero-length slice (backed by `empty_env_backing` on
	//     the stack) because Process_Desc treats env == nil as "inherit
	//     parent" (core/os/process.odin); a freshly-make()d empty slice
	//     is data-nil and compares equal to nil, so it wouldn't work.
	//   - Allowlist contains "*" → full passthrough via env = nil.
	//   - Otherwise → filtered slice from shell_env_filtered.
	// When the disposition is Filtered, shell_env_filtered allocates
	// each entry + the slice via runtime.heap_allocator(); we free both
	// after process_start (Linux execve copies env into the child image).
	filtered_env, env_disposition := shell_env_filtered()
	defer if env_disposition == .Filtered && filtered_env != nil {
		heap := runtime.heap_allocator()
		for s in filtered_env do delete(s, heap)
		delete(filtered_env, heap)
	}

	empty_env_backing: [1]string
	child_env: []string
	switch env_disposition {
	case .Inherit:
		child_env = nil
	case .Empty:
		// Non-nil zero-length slice; data points at `empty_env_backing`
		// so the slice doesn't compare equal to nil.
		child_env = empty_env_backing[:0]
	case .Filtered:
		child_env = filtered_env
	}

	// Start process
	desc := os.Process_Desc {
		command = req.cmd,
		stdout  = stdout_w,
		stderr  = stderr_w,
		stdin   = stdin_r,
		env     = child_env,
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

	// #166: register the child so shell_client_destroy can kill it to bound
	// the shutdown drain. Check `destroying` under the same lock so a request
	// racing destroy can't leave an unkillable child running; unregister on
	// every return path via the defer below.
	if client != nil {
		sync.lock(&client.procs_mutex)
		if sync.atomic_load(&client.destroying) {
			sync.unlock(&client.procs_mutex)
			_ = os.process_kill(process)
			_, _ = os.process_wait(process)
			if stdin_w != nil do os.close(stdin_w)
			response.error_msg = strings.clone("shell client shutting down")
			response.exit_code = -1
			return response
		}
		client.processes[req.id] = process
		sync.unlock(&client.procs_mutex)
	}
	defer if client != nil {
		sync.lock(&client.procs_mutex)
		delete_key(&client.processes, req.id)
		sync.unlock(&client.procs_mutex)
	}

	// #167: stdin is fed inside the poll loop below (POLLOUT) rather than
	// with one blocking os.write. A large stdin to a child that doesn't
	// drain it (or exits early) would otherwise block here forever -- past
	// the timeout/output-cap checks, which only run in the read loop -- and
	// writing to a closed read end would raise SIGPIPE (now ignored).
	stdin_off := 0
	stdin_done := stdin_w == nil

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
		// Deadline check (issue #99 M2 B). time.diff(start, end) returns
		// end - start, so <= 0 means now >= deadline. Checked before the
		// poll so a deadline that has already elapsed kills the child
		// immediately rather than waiting another 50 ms tick.
		if time.diff(time.now(), deadline) <= 0 {
			_ = os.process_kill(process)
			clear(&stdout_buf)
			clear(&stderr_buf)
			response.exit_code = -1
			response.error_msg = fmt.aprintf("shell timeout exceeded %d ms", timeout_ms)
			killed = true
			break
		}

		fds: [3]linux.Poll_Fd
		n_fds := 0
		stdout_idx := -1
		stderr_idx := -1
		stdin_idx := -1
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
		if !stdin_done {
			fds[n_fds] = linux.Poll_Fd {
				fd     = linux.Fd(os.fd(stdin_w)),
				events = {.OUT},
			}
			stdin_idx = n_fds
			n_fds += 1
		}

		n_ready, perr := linux.poll(fds[:n_fds], 50)
		if perr == .EINTR {
			// signal interrupted poll (Raylib installs handlers); retry
			continue
		}
		if perr != .NONE {
			// genuinely fatal poll error (EBADF, ENOMEM, EINVAL) —
			// bail out cleanly; wait below will surface final state.
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
			// #167: feed stdin a chunk at a time, only when the pipe is
			// writable. A write of <= PIPE_BUF (4096) bytes is non-blocking
			// once POLLOUT signals room, so this never blocks the loop and
			// the timeout/cap checks above keep firing. EPIPE/HUP (child
			// closed its read end) ends stdin without a SIGPIPE crash.
			if stdin_idx >= 0 {
				r := fds[stdin_idx].revents
				if .OUT in r {
					chunk := len(req.stdin) - stdin_off
					if chunk > 4096 do chunk = 4096
					n, werr := os.write(stdin_w, transmute([]u8)req.stdin[stdin_off:stdin_off + chunk])
					if werr != nil || n <= 0 {
						stdin_done = true
						os.close(stdin_w)
						stdin_w = nil
					} else {
						stdin_off += n
						if stdin_off >= len(req.stdin) {
							stdin_done = true
							os.close(stdin_w)
							stdin_w = nil
						}
					}
				} else if .ERR in r || .HUP in r {
					stdin_done = true
					os.close(stdin_w)
					stdin_w = nil
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

	// Close the stdin pipe if the child never drained it (timeout/cap kill,
	// or a child that exited without reading all input). #167.
	if stdin_w != nil do os.close(stdin_w)

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
