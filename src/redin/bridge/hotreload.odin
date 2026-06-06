package bridge

import "core:fmt"
import "core:os"
import "core:time"

// F5 (#204): how long after a failed reload to make one more attempt.
// An editor that saves non-atomically (write-in-place rather than
// write-temp-then-rename) can update a watched file's mtime while the
// buffer is still half-written, so the mtime-triggered re-require lands on
// a truncated module and fails with a Fennel syntax error. A single short
// retry gives the editor time to finish the write; 50ms is far longer than
// any in-place save and short enough to feel instant.
HOTRELOAD_RETRY_MS :: 50.0

Hotreload_Trigger :: enum {
	None,    // nothing to do this frame
	Changed, // a watched file's mtime advanced
	Retry,   // a previously-armed one-shot retry came due
}

Hot_Reload :: struct {
	watch_paths:    [dynamic]string,
	last_mtimes:    map[string]i64,
	frame_counter:  int,
	check_interval: int,
	// F5: one-shot retry after a failed reload. retry_armed is true between
	// arming the retry and consuming it; retry_at marks when it was armed.
	// Because it is armed only on a fresh-change failure and consumed once,
	// a genuinely broken file fails at most twice, never in a loop.
	retry_armed:    bool,
	retry_at:       time.Tick,
}

hotreload_init :: proc(hr: ^Hot_Reload, source_tree: bool) {
	hr.check_interval = 60
	if !source_tree do return  // #129 H6: cwd-relative watch list only
	                            // active inside the redin source tree.
	files := []string{
		"src/runtime/dataflow.fnl",
		"src/runtime/effect.fnl",
		"src/runtime/frame.fnl",
		"src/runtime/theme.fnl",
		"src/runtime/view.fnl",
		"src/runtime/init.fnl",
		// #183: also watch these so editing them triggers a reload.
		"src/runtime/agent.fnl",
		"src/runtime/markdown.fnl",
		"src/runtime/canvas.fnl",
	}
	for f in files {
		append(&hr.watch_paths, f)
		hr.last_mtimes[f] = get_file_mtime(f)
	}
}

hotreload_destroy :: proc(hr: ^Hot_Reload) {
	delete(hr.watch_paths)
	delete(hr.last_mtimes)
}

// Pure predicate: given a retry is armed and `elapsed_ms` have passed since
// it was armed, is it due to fire? Factored out so the timing rule is unit-
// testable without a real clock.
hotreload_retry_due :: proc(armed: bool, elapsed_ms: f64) -> bool {
	return armed && elapsed_ms >= HOTRELOAD_RETRY_MS
}

// Pure predicate: after an execute attempt, should a one-shot retry be armed?
// Only when a *fresh* mtime change (not an already-consumed retry) failed —
// this is what bounds a broken file to two attempts instead of a loop.
hotreload_should_arm_retry :: proc(trigger: Hotreload_Trigger, reload_ok: bool) -> bool {
	return trigger == .Changed && !reload_ok
}

hotreload_poll :: proc(hr: ^Hot_Reload) -> Hotreload_Trigger {
	// A pending retry fires on its own time-based deadline, independent of
	// the mtime-poll throttle, and is consumed here so it fires at most once.
	// While a retry is still pending we hold off on mtime polling so the two
	// paths can't interleave.
	if hr.retry_armed {
		elapsed := time.duration_milliseconds(time.tick_since(hr.retry_at))
		if hotreload_retry_due(hr.retry_armed, elapsed) {
			hr.retry_armed = false
			return .Retry
		}
		return .None
	}

	hr.frame_counter += 1
	if hr.frame_counter < hr.check_interval do return .None
	hr.frame_counter = 0

	changed := false
	for path in hr.watch_paths {
		mtime := get_file_mtime(path)
		if old_mtime, ok := hr.last_mtimes[path]; ok {
			if mtime > old_mtime do changed = true
		}
		hr.last_mtimes[path] = mtime
	}
	return changed ? .Changed : .None
}

// Arm a single retry to fire ~HOTRELOAD_RETRY_MS later. retry_at records
// the moment of failure; hotreload_poll fires once that long has elapsed.
hotreload_arm_retry :: proc(hr: ^Hot_Reload) {
	hr.retry_armed = true
	hr.retry_at = time.tick_now()
}

hotreload_execute :: proc(b: ^Bridge) -> (ok: bool) {
	code := `
		package.loaded["dataflow"] = nil
		package.loaded["effect"]   = nil
		package.loaded["frame"]    = nil
		package.loaded["theme"]    = nil
		package.loaded["view"]     = nil
		package.loaded["init"]     = nil
		-- #183: these modules capture dataflow/theme at load time. Without
		-- invalidating them, a reload re-evaluates dataflow into a fresh
		-- module but agent/markdown/canvas keep their stale captures, so
		-- (require :agent).install registers into the old dataflow and the
		-- agent edit channel / overrides break for the rest of the session.
		package.loaded["agent"]    = nil
		package.loaded["markdown"] = nil
		package.loaded["canvas"]   = nil
		require("init")
	`
	if luaL_dostring(b.L, cstring(raw_data(code))) != 0 {
		msg := lua_tostring_raw(b.L, -1)
		fmt.eprintfln("Hot reload error: %s", msg)
		lua_pop(b.L, 1)
		return false
	}
	fmt.println("Hot reload: runtime reloaded")
	return true
}

@(private = "file")
get_file_mtime :: proc(path: string) -> i64 {
	// #162 L1: lstat, not stat — don't dereference symlinks. A symlink
	// swap in the watched directory should be observed as the watched
	// path changing, not silently followed to whatever it now points at.
	fi, err := os.lstat(path, context.temp_allocator)
	if err != os.ERROR_NONE do return 0
	return time.time_to_unix(fi.modification_time)
}
