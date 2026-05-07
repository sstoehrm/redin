# Native bridge API

Public Odin API for `--native` projects. Lets user code in `app.odin` register Lua cfuncs, dispatch events into the Fennel re-frame pipeline, and marshal Odin values to Lua — all without forking framework files.

Import from your `app.odin`:

```odin
import "./.redin/src/redin/bridge"
```

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

These setters install host-side policy for the built-in `redin.http` and `redin.shell` host functions. Both are global, take a slice of strings (cloned internally), and accept `nil` to clear back to the permissive default. Call before or after `redin.run`; changes apply to subsequent requests.

### `bridge.set_http_whitelist(allow: []string)`

When set, `redin.http` accepts only URLs whose host matches an entry. Entries are either hostname literals (case-insensitive — e.g. `"api.example.com"`) or CIDR blocks (IPv4 or IPv6 — e.g. `"127.0.0.0/8"`, `"::1/128"`). CIDR entries are matched only against IP-literal hosts, not DNS names. `nil` (the default) accepts any host.

Rejection failure (delivered to the `:http` effect's `on-error`): `{status: 0, error: "host <name> not in http whitelist"}`.

```odin
bridge.set_http_whitelist([]string{"api.example.com", "127.0.0.0/8"})
redin.run(cfg)
```

### `bridge.set_shell_env_allowlist(allow: []string)`

When set, child processes spawned by `redin.shell` see only env vars whose keys match a list entry. Comparison is exact (case-sensitive on POSIX). `nil` (the default) is full passthrough — children inherit the parent process environment.

The setter does not produce a runtime failure path. It only changes the env that reaches `execve(2)`.

```odin
bridge.set_shell_env_allowlist([]string{"PATH", "HOME", "GITHUB_TOKEN"})
redin.run(cfg)
```

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
