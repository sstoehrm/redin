package bridge

// path_parent_dir returns the directory portion of `path` — everything up
// to the last '/' or '\\' separator — and whether a separator was present.
//
//   "build/redin"   -> ("build", true)
//   "/usr/bin/redin"-> ("/usr/bin", true)
//   "/redin"        -> ("/", true)      // root-anchored, dir is the root
//   "redin"         -> ("", false)      // bare name, no directory
//
// A slice of the input is returned (no allocation), matching the
// tracking-allocator constraints documented at the call site in `init`.
// The `false` case tells the caller argv[0] carried no path — a bare
// $PATH-resolved command name — so it must recover the real install
// directory via /proc/self/exe rather than assume the current directory
// (#233 H1).
@(private = "package")
path_parent_dir :: proc(path: string) -> (dir: string, has_sep: bool) {
	last_sep := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			last_sep = i
			break
		}
	}
	if last_sep < 0 do return "", false
	if last_sep == 0 do return path[:1], true // separator is the root itself
	return path[:last_sep], true
}
