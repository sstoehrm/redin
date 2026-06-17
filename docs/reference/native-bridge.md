# Native bridge API

Public Odin API for `--native` projects. Lets user code in `app.odin` register Lua cfuncs, dispatch events into the Fennel re-frame pipeline, and marshal Odin values to Lua — all without forking framework files.

Import from your `app.odin`:

```odin
import "./.redin/src/redin/bridge"
```

## Trust model

**redin is not a sandbox.** Your app's `.fnl` / `.lua` files are the trusted
principal, not untrusted content. They load with the **full Lua standard
library** — including `os` (`os.execute`, `os.getenv`, `os.remove`), `io`,
`debug`, and `package` — and on top of that the host hands them `redin.shell`
and `redin.http`. App code can therefore run arbitrary commands and read or
write the filesystem with the privileges of the process. This is intentional:
the app *is* the program, so withholding `os.execute` while shipping
`redin.shell` would be theatre.

The deny-by-default effect policies below (`set_http_whitelist`,
`set_shell_env_allowlist`) and the SSRF/CRLF hardening on `redin.http` are
defense-in-depth for the *host-configured* surface — they bound what a bug or
a compromised remote endpoint can reach. They are **not** a boundary that
contains hostile app code: code with `os`/`io`/`package` can ignore the
framework entirely. Treat the `.fnl`/`.lua` you load with the same trust you'd
give a native plugin compiled into the binary.

Concretely: **do not** use redin to run third-party `.fnl`/`.lua` widgets,
user-submitted scripts, or any code you would not run as a shell command. If
you ever need to host untrusted UI code, the isolation must come from outside
redin (a separate process, an OS sandbox, a container) — there is no
in-framework setting that makes loading untrusted scripts safe.

## Cfunc registration

### `bridge.register_cfunc(name: cstring, fn: proc(L: ^Lua_State) -> i32)`

Registers a Lua-callable function under `redin.<name>`. Pass a regular Odin proc — **not** `proc "c"`. The bridge wraps it in a static trampoline that sets `context = bridge.host_context()` and dispatches via a Lua upvalue.

```odin
my_signal :: proc(L: ^bridge.Lua_State) -> i32 {
    // Context is already set; tracking allocator is live; no ceremony.
    n := lua_tointeger(L, 1)
    fmt.eprintfln("got signal %d", n)
    return 0  // number of return values pushed onto the stack
}

main :: proc() {
    bridge.register_cfunc("my_signal", my_signal)
    redin.run({app = "main.fnl"})
}
```

From Fennel: `(redin.my_signal 42)`. From Lua: `redin.my_signal(42)`.

**Timing:** safe before *or* after `bridge.init`. Registrations made before `redin.run` (which is when `bridge.init` runs) are buffered and flushed inside init, after the `redin` Lua global is created.

**Duplicate names:** silent replace. When the binary was built with `-define:REDIN_DEV=true`, logs a stderr warning before replacing — same policy as `canvas.register`.

### `bridge.register_cfunc_raw(name: cstring, fn: Lua_CFunction)`

Escape hatch for raw `proc "c"` cfuncs. The caller is responsible for `context = bridge.host_context()` at entry. Use only when you genuinely need the raw C calling convention (e.g. integrating with another C library).

### `bridge.host_context() -> runtime.Context`

Returns the runtime context the bridge captured during `init`. Only needed by `register_cfunc_raw` callers — `register_cfunc`'s trampoline sets it for you.

## Marshalling

### `bridge.push(L: ^Lua_State, value: any)`

Pushes one Odin value onto the Lua stack. Reflection-based; supported types:

| Odin type | Lua representation |
|---|---|
| `nil`, nil pointer | Lua nil |
| `bool` | Lua boolean |
| integer (`i8..i64`, `u8..u64`), enum | Lua number |
| `f32`, `f64` | Lua number |
| `string`, `cstring` | Lua string |
| `[]T`, `[N]T`, `[dynamic]T` | Lua array table (1-indexed) |
| `map[string]T` (and other key types) | Lua keyed table |
| `struct` | Lua keyed table; field names → keys |
| `union` | active variant pushed; `nil` if unset |
| `^T` | dereferences and recurses; `nil` if pointer is nil |
| `any` | recurses on the wrapped value |

Unsupported types push `nil` and log a stderr warning. Bails at recursion depth 32 with a warning to guard against cycles.

```odin
Combat_State :: struct {
    player_hp: i32,
    enemy_hp:  i32,
    items:     []string,
}

bridge.push(L, Combat_State{player_hp = 100, enemy_hp = 50, items = []string{"sword", "shield"}})
// Lua sees: {player_hp = 100, enemy_hp = 50, items = {"sword", "shield"}}
```

## Dispatch (native → Fennel)

`redin_events` is the Fennel-side dispatch channel (`view.deliver-events`). Both verbs below append `["dispatch", [event_name, payload]]` to a one-element events array and call it.

### `bridge.dispatch(event: string, payload: any) -> (ok: bool, err: string)`

High-level: marshal the payload via `push` and dispatch.

```odin
ok, err := bridge.dispatch("combat/push", combat_state)
if !ok do fmt.eprintfln("dispatch failed: %s", err)
```

Fennel side:

```fennel
(reg-handler :combat/push
  (fn [db event]
    (let [payload (. event 2)]
      (assoc db :combat payload))))
```

### `bridge.dispatch_tos(L: ^Lua_State, event: string) -> (ok: bool, err: string)`

Zero-copy hot-path variant: the caller has already pushed the payload onto the top of the Lua stack using raw `lua_*` helpers. Use this for per-frame state pushes where reflection cost matters.

The payload is consumed regardless of success.

```odin
// Caller built a custom Lua table on the stack already.
build_combat_table_on_stack(L, &combat)
ok, err := bridge.dispatch_tos(L, "combat/push")
```

## Effect policy setters

These setters install host-side policy for the built-in `redin.http` and `redin.shell` host functions. Both are global, take a slice of strings (cloned internally), and accept `nil` to reset to the deny-by-default state. Call before or after `redin.run`; changes apply to subsequent requests.

**Deny-by-default (#136 H2, H3).** When the setter has not been called (or has been called with `nil` or an empty slice), the corresponding surface is closed:

- `redin.http` → every outbound host is rejected with `host <name> not in http whitelist`.
- `redin.shell` → spawned children get an empty environment.

To re-enable the historical open-by-default behaviour, pass the wildcard sentinel (`"*"`, or the equivalent `"all"` access class for HTTP):

```odin
bridge.set_http_whitelist([]string{"all"})       // accept any host ("*" is an alias)
bridge.set_shell_env_allowlist([]string{"*"})    // full parent-env passthrough
```

For `redin.http`, prefer the `"local"` / `"external"` access classes over `"all"` when you can — they bound which IP ranges are reachable and close SSRF/DNS-rebinding. See `bridge.set_http_whitelist` below. For `set_shell_env_allowlist`, `"*"` works with the rest of the list (e.g. `[]string{"*", "extra"}`), though there's no reason to mix it with real entries — the wildcard always matches first.

### `bridge.set_http_whitelist(allow: []string)`

Configures which hosts `redin.http` will dial. Entries are one of:

- **An access-class keyword** controlling which IP *ranges* are reachable:
  - `"all"` — any address (the historical open-by-default behaviour; `"*"` is a back-compat alias).
  - `"local"` — loopback only (`127.0.0.0/8`, `::1`).
  - `"external"` — public addresses only; loopback, link-local, RFC1918, ULA, CGNAT, and cloud-metadata (`169.254.169.254`) ranges are blocked.
- **A hostname literal** (case-insensitive — e.g. `"api.example.com"`).
- **A CIDR block** (IPv4 or IPv6 — e.g. `"127.0.0.0/8"`, `"::1/128"`).

Hostname and CIDR entries are **always allowed**, on top of whatever the class permits — so `[]string{"external", "127.0.0.1"}` reaches public hosts *plus* that one loopback service. If multiple class keywords appear, the most permissive wins.

**SSRF / DNS-rebinding defence (#162 M3):** the access class is enforced against the **resolved IP**, not the URL text. redin resolves the host itself, checks the resolved address against the class, then dials that exact endpoint. So a public hostname that resolves into a blocked range (`evil.example → 127.0.0.1`) is rejected under `"local"`/`"external"` — a literal-string check would miss it. An explicit hostname or CIDR entry still overrides this (the explicit opt-in is intentional).

Hostname comparison is ASCII-byte case-insensitive, and a single trailing root-label dot is insignificant on either side — `"example.com"` in the whitelist matches a request to `example.com.` and vice versa. IDN hostnames must be passed in their punycode (`xn--...`) form — `münchen.example` is not equivalent to `xn--mnchen-3ya.example`, and the URL parser punycodes the request host before matching.

Rejection failure (delivered to the `:http` effect's `on-error`): `{status: 0, error: "host <name> not in http whitelist"}`.

```odin
// Restrict to specific hosts (plus any loopback in 127/8):
bridge.set_http_whitelist([]string{"api.example.com", "127.0.0.0/8"})

// Public internet only — block SSRF into loopback/LAN/metadata:
bridge.set_http_whitelist([]string{"external"})

// A local companion service plus the public internet:
bridge.set_http_whitelist([]string{"external", "127.0.0.1"})

// Open it up entirely (pre-#136 default):
bridge.set_http_whitelist([]string{"all"})   // or "*"

redin.run(cfg)
```

### `bridge.set_shell_env_allowlist(allow: []string)`

Configures which environment variables `redin.shell` passes to spawned children. Entries are env-var KEY names; comparison is exact (case-sensitive on POSIX). The sentinel entry `"*"` requests full passthrough.

The setter does not produce a runtime failure path — it only changes the env that reaches `execve(2)`.

```odin
// Specific keys:
bridge.set_shell_env_allowlist([]string{"PATH", "HOME", "GITHUB_TOKEN"})

// Full passthrough (pre-#136 default):
bridge.set_shell_env_allowlist([]string{"*"})

redin.run(cfg)
```

Tools that resolve their command via `$PATH` (e.g. `bb`, `git`, `gh`) will fail with "command not found" when the allowlist is empty and the child has no `PATH`. Either pass absolute paths in `cmd`, or list `"PATH"` (and whatever else the command needs).

## Calling conventions and context

| Convention | Context propagates? | When you write it |
|---|---|---|
| `proc()` (Odin default) | yes | `on_init`, `on_input`, `on_frame`, `on_shutdown`, `register_cfunc` callbacks |
| `proc "c"` | no — must `context = ...` explicitly | `register_cfunc_raw` callbacks only |

Hooks registered via `redin.on_*` are called from inside `redin.run`, which already has `host_context()` set, so context inherits naturally. User cfuncs registered via `register_cfunc` go through the trampoline. The only place `proc "c"` discipline applies is `register_cfunc_raw`.

## See also

- [Canvas providers](canvas.md) — symmetric callback model for visual native work
- [Effects](effects.md) — the Fennel-facing dispatch interface
- [`docs/core-api.md`](../core-api.md) — built-in `redin.*` host functions exposed by the framework
