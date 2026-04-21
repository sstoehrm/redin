package bridge

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

Shell_Request :: struct {
	id:    string,
	cmd:   []string,
	stdin: string,
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

@(private = "file")
execute_shell :: proc(req: Shell_Request) -> Shell_Response {
	response: Shell_Response
	response.id = strings.clone(req.id)

	if len(req.cmd) == 0 {
		response.error_msg = strings.clone("Empty command")
		response.exit_code = -1
		return response
	}

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

	// Start process
	desc := os.Process_Desc {
		command = req.cmd,
		stdout  = stdout_w,
		stderr  = stderr_w,
		stdin   = stdin_r,
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

	// Blocking reads on child pipes. The previous version gated each
	// read on os.pipe_has_data and fell through to os.read in both
	// branches — same behaviour, extra syscall, and on macOS/BSD the
	// has_data probe could false-negative and turn a quick command
	// into a hang (the `else` branch still called os.read after the
	// probe said "nothing there"). Direct blocking reads are simpler
	// and work on all platforms: when the child exits and closes its
	// pipe, os.read returns 0 / error and we mark that side done.
	for !stdout_done || !stderr_done {
		if !stdout_done {
			n, err := os.read(stdout_r, read_buf[:])
			if err != nil || n <= 0 {
				stdout_done = true
			} else {
				append(&stdout_buf, ..read_buf[:n])
			}
		}
		if !stderr_done {
			n, err := os.read(stderr_r, read_buf[:])
			if err != nil || n <= 0 {
				stderr_done = true
			} else {
				append(&stderr_buf, ..read_buf[:n])
			}
		}
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
