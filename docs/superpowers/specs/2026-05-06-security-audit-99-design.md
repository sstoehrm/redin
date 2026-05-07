# Security audit fixes (#99) — design

## Goal

Implement all eight findings from the bridge / devserver / http / shell security audit (issue #99). Land them on a single branch (`fix/security-audit-99`) with the medium-severity fixes (M1–M5) and low-severity fixes (L1–L3) treated as one coherent piece of work.

The redin trust model is unchanged: the `.fnl` / `.lua` app file is trusted code with full Lua + bridge access. The dev-server (gated on `REDIN_DEV` / `REDIN_AGENT`) is the externally reachable surface. These fixes harden both layers without changing the trust model.

## Posture summary

For findings with a behavior choice, the design is **permissive default + opt-in hardening tool**:

- Existing apps continue to run unchanged.
- Apps that want stricter behavior call a public bridge setter at startup (`set_http_whitelist`, `set_shell_env_allowlist`).
- Findings that are pure DoS / robustness fixes (M1, M2, L1, L2) get reasonable defaults baked in. The defaults can be overridden per-call where it makes sense (M1 timeout, M2 cap + timeout).

## Fixes

### M1 — HTTP request timeout + concurrency cap

`src/redin/bridge/http_client.odin`, `src/redin/bridge/bridge.odin`

- Add `timeout: time.Duration` to `Http_Request`. Default **30 s**.
- Per-call override on the `:http` effect map: `:timeout 60` (seconds, integer or float).
- Plumb the timeout into odin-http via its existing request-deadline knob. If odin-http exposes none, wrap the call in a watchdog that closes the underlying socket on expiry.
- `MAX_INFLIGHT_HTTP = 64` (compile-time const). `redin_http` rejects new requests when in-flight count is at the cap; counter decremented in `http_thread_proc` on completion.
- Failure response (timeout or cap): `{status: 0, error: "http timeout exceeded 30s"}` or `{status: 0, error: "too many concurrent http requests (cap 64)"}`. No body, no headers, no partial data.

### M2 — Shell output cap + timeout

`src/redin/bridge/shell.odin`, `src/redin/bridge/bridge.odin`

- `SHELL_MAX_OUTPUT = 16 * 1024 * 1024` (compile-time const, mirrors `HTTP_MAX_BODY`). Per-call override `:max-output 32` (MiB) on the `:shell` map.
- `SHELL_DEFAULT_TIMEOUT = 30 * time.Second`. Per-call override `:timeout 60` (seconds).
- During the read loop in `execute_shell`: after each append, check `len(stdout_buf) + len(stderr_buf) > cap`. On exceedance, `os.process_kill(process)`, set `error_msg = "shell output exceeded 16 MiB cap"`, `exit_code = -1`, and clear `stdout` / `stderr` (no partial data returned).
- Timeout enforced via a deadline check in the read loop (poll-based using `SO_RCVTIMEO` on the pipe + elapsed-time check). On expiry: kill child, return `error_msg = "shell timeout exceeded 30s"`, `exit_code = -1`, empty buffers.

### M3 — Shell env allowlist

`src/redin/bridge/shell.odin`, `src/redin/bridge/api.odin`

- New public bridge API: `bridge.set_shell_env_allowlist(allow: []string)`. Stores a clone in a package-global `shell_env_allowlist: []string` (nil = unset).
- In `execute_shell`:
  - If allowlist is **set**: build `desc.env` from `os.environ()` filtered to keys present in the allowlist (exact match, case-sensitive).
  - If allowlist is **unset** (default): leave `desc.env = nil` so the child inherits the full parent env (current behavior).
- No glob support in v1; can be added later if needed.
- Setter callable any time, including from a Lua cfunc registered by the user's `app.odin`. Concurrent access protected by a new package-level `sync.Mutex` for the allowlist slice (the bridge currently has only per-client mutexes such as the shell client's `results_mutex`; the new mutex is dedicated to the allowlist). Same pattern applies to the M4 whitelist.

### M4 — HTTP scheme guard + destination whitelist

`src/redin/bridge/http_client.odin`, `src/redin/bridge/api.odin`

- **Always** (non-bypassable): reject URLs whose scheme is not `http` or `https`. Failure: `{status: 0, error: "http scheme must be http or https"}`.
- New public bridge API: `bridge.set_http_whitelist(allow: []string)`. Stores a clone of the input. nil = unset (default = any host allowed).
- Each entry is either a hostname literal (case-insensitive exact match against the URL host) **or** a CIDR (IPv4 or IPv6, matched against URL hosts that are already IP literals). Hostnames are not resolved to IPs at validation; the app is trusted, so this is self-protection, not anti-hostile-app defense.
- When set: parse URL host, reject if it doesn't match any whitelist entry. Failure: `{status: 0, error: "host <name> not in http whitelist"}`.
- The whitelist is checked alongside the scheme check in `redin_http` before the request is queued.

### M5 — Header CRLF / NUL validation

`src/redin/bridge/http_client.odin`

- New helper `header_value_safe(s: string) -> bool`: returns `false` if `s` contains `\r`, `\n`, or `\x00`. Same check on key.
- In `redin_http`, before queuing the request: iterate `req.headers`, fail the call if any header key or value fails the check. Failure: `{status: 0, error: "http header contains invalid character"}`. No silent stripping — fail loud.

### L1 — Content-Length overflow guard

`src/redin/bridge/devserver.odin` (`find_content_length`, caller at line ~266)

- Cap digit count to 12 inside `find_content_length`; return `-1` if exceeded.
- Caller adds a sibling check `cl < 0` → `400 Bad Request`. Existing `cl > MAX_BODY` → `413` path is preserved.
- Negative result also covers any future overflow surprise without further parser changes.

### L2 — Token / port file write becomes fatal

`src/redin/bridge/devserver.odin` (~lines 172–180)

- If `write_private_no_follow(TOKEN_FILE, ...)` or the corresponding `.redin-port` write fails, log `"redin: failed to write .redin-token; aborting dev server"` (or analogous for the port file) on stderr, set `ds.running = false`, and return.
- Affects only `REDIN_DEV` / `REDIN_AGENT` builds (the only ones where this code runs). Replaces the current "log warning, keep running" UX which produces silent 401s on every request.

### L3 — Disable HTTP auto-redirects

`src/redin/bridge/http_client.odin`

- Set odin-http's redirect-follow option to `false` at `request_init`. Verify the exact field name during impl (likely something like `req.follow_redirects = false` or a max-hop count of 0).
- 3xx responses surface to the Lua app as-is (status, headers including `Location`, body). Apps that want to follow a redirect can re-issue the request themselves.
- Closes the SSRF-via-redirect concern even when M4's whitelist is opt-in.

## Public API additions

```odin
// src/redin/bridge/api.odin
bridge.set_shell_env_allowlist :: proc(allow: []string)  // nil = unset
bridge.set_http_whitelist      :: proc(allow: []string)  // nil = unset
```

Both clone the slice contents into bridge-owned memory. Callable before or after `bridge.init`. Available to `--native` `app.odin` callers via the public bridge package.

## Effect-map additions

| Effect | New optional key | Type | Default | Behavior |
|---|---|---|---|---|
| `:http` | `:timeout` | seconds (number) | 30 | Per-call override of `M1` timeout |
| `:shell` | `:timeout` | seconds (number) | 30 | Per-call override of `M2` timeout |
| `:shell` | `:max-output` | MiB (integer) | 16 | Per-call override of `M2` output cap |

No removals. No renames.

## Error response shape (unchanged)

All hardening rejections produce responses in the existing shape:

- HTTP: `{status: 0, error: "<message>", body: "", headers: {}}`
- Shell: `{exit_code: -1, error_msg: "<message>", stdout: "", stderr: ""}`

The Fennel app's `:on-error` handler (or the existing `(if (= 0 status) ...)` / `(if (not= 0 exit-code) ...)` branch) handles these the same as today's start failures and HTTP errors. No new event shapes.

## Documentation

Updated in the same commits as the code changes (per CLAUDE.md):

| File | What changes |
|---|---|
| `docs/core-api.md` | Dev-server table notes 400 for malformed Content-Length. `redin.http` / `redin.shell` sections document `:timeout`, `:max-output`, default values, error response shape, scheme rejection (M4), header validation (M5), redirect non-following (L3). |
| `docs/reference/native-bridge.md` | Add `set_shell_env_allowlist` and `set_http_whitelist` to the public bridge API table. |
| `docs/reference/effects.md` | Add the new effect-map keys (`:timeout` for `:http` / `:shell`; `:max-output` for `:shell`) and document the failure paths. |
| `docs/reference/dev-server.md` | Note the 400 path for malformed Content-Length; mention that token-file write failure aborts startup. |
| `docs/guide/*.md` | Sweep for `redin.http` / `redin.shell` examples that would mislead a reader (e.g. examples relying on auto-redirect behavior). |
| `.claude/skills/redin-dev/SKILL.md` | Add the new optional fields on `:http` / `:shell` and the two new public-bridge setters. |
| `CLAUDE.md` | Skim only — likely no change. The conventions list does not currently mention these specifics. |

## Testing

### Odin unit tests (`src/redin/bridge/*_test.odin`)

- `http_client_test.odin` — extend with:
  - Scheme rejection (`ftp://`, `file://`, empty, mixed-case `HTTP`).
  - Header CRLF / NUL rejection (each forbidden char in key, then in value).
  - Whitelist hostname match (case-insensitive).
  - Whitelist CIDR match (IPv4 and IPv6 literal hosts).
  - Whitelist mismatch returns error containing the rejected host.
  - 3xx responses surface to the caller without following.
- `shell_test.odin` (new) —
  - Output-cap kill: synthesise an over-cap buffer, assert error_msg, empty stdout/stderr, exit_code -1, child killed.
  - Env-allowlist filtering: set allowlist, run `env`, parse output, assert only allowlisted keys present; clear allowlist, assert full passthrough.
  - Timeout kill: launch `sleep 60` with `:timeout 1`, assert error_msg + exit_code -1.
- `devserver_headers_test.odin` — extend with:
  - `find_content_length` returns `-1` on >12 digits and on multiplication overflow.
  - End-to-end: `Content-Length: 999999999999999999` → 400.
- `devserver_write_test.odin` — extend with:
  - Token-write failure aborts server start (mock `write_private_no_follow`, assert `ds.running == false`).

### Fennel runtime tests (`test/lua/`)

- `test_effect.fnl` (or similar): one round-trip test confirming `:timeout` / `:max-output` on `:http` / `:shell` are passed through to the bridge call without runtime errors. The runtime side is otherwise unchanged.

### UI integration tests (`test/ui/`)

No new test app. The hardening fixes are server-side and not UI-visible. The existing `test/ui/run-all.sh --headless` run is the regression check.

### Manual / smoke

- Release build: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin` — confirm no new warnings, no missing imports, devserver code is excluded as expected.
- Dev build: `./build-dev.sh` — confirm dev binary builds.
- Agent build: `./build-dev.sh -define:REDIN_AGENT=true` — confirm agent path still compiles (the new setters live in the bridge, loaded both ways).
- Tracking-allocator smoke: dev binary on `test/ui/smoke_app.fnl`, dispatch a few `:http` and `:shell` calls (success + cap + timeout paths), verify no leaks on shutdown — especially around cloned allowlist slices and timed-out request cleanup.

### Verification gates (per `redin-maintenance` skill)

In order, before declaring done:

1. `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
2. `./build-dev.sh`
3. `luajit test/lua/runner.lua test/lua/test_*.fnl`
4. `odin test src/redin/bridge` (with `-define:ODIN_TEST_THREADS=1` if races appear)
5. `bash test/ui/run-all.sh --headless`
6. Tracking-allocator smoke on the dev binary

## Out of scope

- Glob / pattern support in `set_shell_env_allowlist` (v1 is exact match).
- DNS-resolve-and-classify SSRF defense for `redin.http` (treated as out of scope per the trust model; the audit flagged it but the user opted for permissive default + opt-in whitelist).
- Per-call `:env` field on `:shell` (current design is global allowlist via the bridge setter; per-call control can be added later if a real use case appears).
- Hop-by-hop redirect re-validation (not needed once auto-redirects are disabled).
