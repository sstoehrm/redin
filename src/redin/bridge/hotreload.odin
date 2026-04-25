package bridge

import "core:fmt"
import "core:os"
import "core:time"

Hot_Reload :: struct {
	watch_paths:    [dynamic]string,
	last_mtimes:    map[string]i64,
	frame_counter:  int,
	check_interval: int,
}

hotreload_init :: proc(hr: ^Hot_Reload) {
	hr.check_interval = 60
	files := []string{
		"src/runtime/dataflow.fnl",
		"src/runtime/effect.fnl",
		"src/runtime/frame.fnl",
		"src/runtime/theme.fnl",
		"src/runtime/view.fnl",
		"src/runtime/init.fnl",
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

hotreload_check :: proc(hr: ^Hot_Reload) -> bool {
	hr.frame_counter += 1
	if hr.frame_counter < hr.check_interval do return false
	hr.frame_counter = 0

	changed := false
	for path in hr.watch_paths {
		mtime := get_file_mtime(path)
		if old_mtime, ok := hr.last_mtimes[path]; ok {
			if mtime > old_mtime do changed = true
		}
		hr.last_mtimes[path] = mtime
	}
	return changed
}

hotreload_execute :: proc(b: ^Bridge) {
	code := `
		package.loaded["dataflow"] = nil
		package.loaded["effect"]   = nil
		package.loaded["frame"]    = nil
		package.loaded["theme"]    = nil
		package.loaded["view"]     = nil
		package.loaded["init"]     = nil
		require("init")
	`
	if luaL_dostring(b.L, cstring(raw_data(code))) != 0 {
		msg := lua_tostring_raw(b.L, -1)
		fmt.eprintfln("Hot reload error: %s", msg)
		lua_pop(b.L, 1)
	} else {
		fmt.println("Hot reload: runtime reloaded")
	}
}

@(private = "file")
get_file_mtime :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != os.ERROR_NONE do return 0
	return time.time_to_unix(fi.modification_time)
}
