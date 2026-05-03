# Agent channel for in-app user/agent interaction

**Status:** design
**Date:** 2026-05-01

## Problem

Today the redin dev server lets an external agent drive the app from
outside (testing, exploration). It does not provide a way for an app
to *embed* an agent conversation surface — i.e. an end user running
the app interacts with an agent via the UI itself.

Use cases:
- A redin app that integrates Claude or another LLM as a sidecar.
- An app where the agent renders region-specific content (suggestions,
  status, computed results) into a designated container.
- An app that exposes some state to an agent for inspection (read-only
  fields the agent can poll).

## Goals

- App authors mark nodes with an `:agent` attribute and an `:id`. The
  framework handles the rest — no custom wiring required to consume
  agent-written content.
- Agent reads and writes through HTTP endpoints in the same
  request/response style as the existing dev server.
- The whole feature is **off in default builds** — no extra binary
  size, no extra surface, no risk of accidental exposure.
- Channel works in production-like runs (no `--dev` required).

## Non-goals

- Streaming partial writes (each PUT replaces the full content).
- Push notifications to the agent (agent polls; long-polling /
  websockets deferred).
- Markdown rendering of agent-posted text — split into issue #100.
- Container-level write validation beyond shape (the agent posting an
  invalid frame fragment surfaces as a runtime warning, not a 400 —
  same as today's hot-reload of malformed Fennel).
- Per-node permissions beyond the read/edit binary. No multi-agent
  isolation, no audit log.

## Design overview

Five layers:

1. **Agent module** — new package `src/redin/agent/`, only compiled
   when `-define:REDIN_AGENT=true`.
2. **Node attribute** — `:agent` on every node type except `:canvas`,
   parsed once, stored as an `Agent_Mode` enum field on each node.
3. **Fennel runtime support** — `src/runtime/agent.fnl` registers a
   handler for `:event/agent-edit` that writes into `db.agent[id]`.
   Apps subscribe via `(subscribe [:agent <id>])`.
4. **Dev-server endpoints** — three new routes (`/agent/nodes`,
   `GET/PUT /agent/content/<id>`), gated on the compile flag.
5. **HTTP listener gating** — listener starts when *either* `--dev` is
   set *or* `REDIN_AGENT` is compiled in, so production-shipped apps
   with the flag get the agent endpoints without dev tools.

### Layer 1 — agent module

`src/redin/agent/agent.odin` (only compiled when `REDIN_AGENT`):

```odin
package agent

Agent_Mode :: enum u8 { None, Read, Edit }

Agent_Node :: struct {
    id:   string,
    mode: Agent_Mode,
    kind: string,  // "text" | "input" | "button" | "image" | "vbox" | ...
}

// Walk the current view tree and return every node tagged :read or :edit.
discover :: proc(...) -> []Agent_Node { ... }
```

Empty when not compiled — Odin's `when REDIN_AGENT` blocks gate the
package's import everywhere it is used, so removing the flag removes
the package from the build.

### Layer 2 — node attribute parsing

Add `agent: Agent_Mode` field to every node struct except `NodeCanvas`
in `src/redin/types/view_tree.odin`. The bridge's `lua_read_node`
reads the `:agent` slot from the Lua attrs table:

```odin
lua_getfield(L, attrs_idx, "agent")
defer lua_pop(L, 1)
if lua_isstring(L, -1) {
    s := string(lua_tostring_raw(L, -1))
    switch s {
    case ":read", "read": node.agent = .Read
    case ":edit", "edit": node.agent = .Edit
    case:                 // unknown — leave as None
    }
}
```

`:canvas` rejects `:agent` at parse time (warn to stderr, ignore).

### Layer 3 — Fennel runtime support

`src/runtime/agent.fnl`:

```fennel
(local dataflow (require :dataflow))

(fn handle-edit [db ev]
  (let [id (. ev :id)
        content (. ev :content)]
    (assoc-in db [:agent id] content)))

{:install (fn []
            (dataflow.reg-handler :event/agent-edit handle-edit))}
```

`init.fnl` calls `((require :agent) :install)` at boot — bundled in
default builds (the file is small) but inert when no `:event/agent-edit`
ever fires. The agent slot in `db` (i.e. `db.agent`) only materialises
when the first edit arrives.

When rendering an agent-tagged node, the framework checks
`db.agent[id]` first and uses that as content if present, falling back
to the literal node content (text/value/children) otherwise. The
"first" check is implemented at view evaluation in Fennel.

#### Per-node-type semantics

| Node type | `:agent :read` returns | `:agent :edit` accepts |
|---|---|---|
| `:text` | the displayed text string | string → replaces text |
| `:input` | current value (live, every keystroke) | string → sets value |
| `:button` | the button label string | string → sets label |
| `:image` | the source path/url | string → sets source |
| `:vbox` `:hbox` `:stack` `:popout` `:modal` | JSON array (`/frames` shape) | JSON array → replaces children |
| `:canvas` | rejected at parse time | rejected at parse time |

For container `:edit`, the agent's posted children pass through the
existing flat-array conversion as a normal Fennel-pushed frame.

### Layer 4 — dev-server endpoints

All endpoints require `Authorization: Bearer <token>` and the
`Host: localhost:<port>` check (existing pattern). All return
`{"ok":true}` / `{"content":...}` on success or
`{"error":"..."}` with appropriate 4xx on failure.

| Method | Path | Description |
|---|---|---|
| GET | `/agent/nodes` | `[{id, mode, type}, ...]` for every node tagged `:read`/`:edit` in the most recently rendered frame. Empty list if none. |
| GET | `/agent/content/<id>` | `{"content": <string-or-tree>}` for the named node. **404** if id missing in current frame. |
| PUT | `/agent/content/<id>` | Body: `{"content": <string-or-array>}`. Dispatches `:event/agent-edit {id, content}`. **404** if id missing. **403** if node is `:agent :read`. **400** if body shape doesn't match the node type (e.g. array for a `:text`). |

Each route's match arm in `process_request` is gated on
`when REDIN_AGENT` — without the flag the arm doesn't exist and the
default 404 handler responds.

### Layer 5 — HTTP listener gating

`src/redin/bridge/bridge.odin` currently gates the dev-server listener
on `b.dev_mode`. Update both `init` and `poll_devserver`:

```odin
init :: proc(b: ^Bridge, dev_mode: bool) {
    b.dev_mode = dev_mode
    needs_listener := b.dev_mode
    when REDIN_AGENT {
        needs_listener = true
    }
    if needs_listener {
        devserver_init(...)
    }
    ...
}

poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent,
                      node_rects: []rl.Rectangle) {
    needs_poll := b.dev_mode
    when REDIN_AGENT {
        needs_poll = true
    }
    if !needs_poll do return
    ...
}
```

Existing dev endpoints stay gated on `b.dev_mode` inside
`process_request` — no change there. Agent endpoints are gated only on
the compile flag, so a production build with `REDIN_AGENT` exposes
only `/agent/*` (everything else 404s).

## Example app

`examples/ai-chat.fnl`:

```fennel
(local dataflow (require :dataflow))
(local theme    (require :theme))

(theme.set-theme
  {:surface       {:bg [30 33 42] :padding [16 16 16 16]}
   :user-bubble   {:bg [60 80 110] :color [240 240 240]
                   :padding [8 12 8 12] :radius 6}
   :agent-bubble  {:bg [40 50 60]  :color [220 230 240]
                   :padding [8 12 8 12] :radius 6}
   :user-input    {:bg [25 28 35] :color [240 240 240]
                   :padding [8 8 8 8] :radius 4}})

(dataflow.init {:typed ""})

(reg-handler :event/typed     (fn [db ev] (assoc db :typed (. ev :value))))
(reg-handler :event/submitted (fn [db _]  (assoc db :typed "")))

(reg-sub :sub/typed (fn [db] (db :typed)))
(reg-sub :sub/reply (fn [db] (get-in db [:agent :reply] "")))

(fn view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:text  {:id :reply :agent :edit :aspect :agent-bubble} "…"]
    [:input {:id :user-input :agent :read :aspect :user-input
             :value (subscribe :sub/typed)
             :change :event/typed
             :submit :event/submitted}
            ""]])
```

Comments in the example explain it requires
`-define:REDIN_AGENT=true` and that markdown rendering arrives in
issue #100.

### Runtime flow

1. User types `"What's 2+2?"` into the input. Each keystroke
   dispatches `:event/typed`, updating `db.typed`. Because the input
   is `:agent :read`, `GET /agent/content/user-input` returns the
   live value.
2. Agent polls `/agent/nodes` to discover the surface, polls
   `/agent/content/user-input`, decides on a reply, and `PUT`s to
   `/agent/content/reply` with `{"content":"4"}`.
3. Server validates id exists, mode is `:edit`, body shape matches
   text node. Dispatches `:event/agent-edit {:id "reply" :content "4"}`.
4. Fennel handler stores into `db.agent.reply`. Next frame, the
   `:text {:id :reply :agent :edit}` node sources its content from
   `db.agent.reply` instead of the literal `"…"`.
5. The app can also `(subscribe :sub/reply)` to react — e.g., push the
   reply into a history list when the user submits.

## Testing

`test/ui/agent_app.fnl` + `test/ui/test_agent.bb`. The bb suite asserts:

- `/agent/nodes` returns the expected `:read`/`:edit` nodes after the
  app boots.
- `PUT /agent/content/<edit-id>` updates the rendered content.
- `GET /agent/content/<read-id>` reflects the current input value
  after a dispatched change event.
- `PUT` to a `:read` node returns 403.
- `PUT` with wrong body shape returns 400.
- `GET` for a missing id returns 404.

The runner skips this suite when the binary lacks the `REDIN_AGENT`
flag. Detection: `GET /agent/nodes` returns 404 (route not compiled
in). The runner probes once at suite start and skips on 404.

## CI

Add a second build job to `.github/workflows/test.yml`:

- Default job (existing): build without `-define:REDIN_AGENT=true`,
  run the standard suite.
- New job: build with `-define:REDIN_AGENT=true`, run the standard
  suite *plus* the agent suite. This guards against the agent code
  bit-rotting silently.

## Release packaging

`release.yml` produces an extra artifact per release with
`-define:REDIN_AGENT=true`, named e.g.
`redin-v<version>-agent-linux-amd64.tar.gz`. Default artifacts stay
agent-free.

## Failure modes and edge cases

- **Agent writes to a node whose id no longer exists in the current
  frame.** PUT returns 404. The dispatch never fires. App state is
  unchanged.
- **Agent posts a JSON array to a non-container node** (or string to
  a container). PUT returns 400 before dispatch.
- **Multiple `:agent` nodes share an id.** First match in DFS order
  wins for read; PUT updates `db.agent[id]` regardless, every node
  with that id renders the same content. App authors should keep ids
  unique.
- **App restarts.** `db.agent` is in-memory only; agent must
  re-discover and re-write on restart.
- **`agent.fnl` not bundled** (someone deletes the file before
  building). `init.fnl` swallows the require failure and skips
  `:install`. The PUT route still dispatches but no handler exists,
  so dataflow logs `No handler registered for: event/agent-edit`.
  Acceptable: this is operator misconfiguration.

## Documentation

- `CLAUDE.md` — note `REDIN_AGENT` build flag, three new endpoints in
  the dev-server table.
- `docs/core-api.md` — add `:agent` attribute, agent-channel section.
- `docs/reference/dev-server.md` — `/agent/*` endpoints with examples.
- `docs/reference/elements.md` — per-element `:agent` semantics column.
- `.claude/skills/redin-dev/SKILL.md` — node-types and dev-server
  table updates.
- `.claude/skills/redin-maintenance/SKILL.md` — `REDIN_AGENT` build
  flag in the verification matrix.

## Out of scope (future work)

- Markdown rendering — issue #100.
- Streaming agent writes (partial / append).
- Push notifications to the agent (websocket / SSE).
- Multi-agent isolation, per-id ACLs, audit log.
- Agent-side typed schema for container content (JSON-Schema validation).
