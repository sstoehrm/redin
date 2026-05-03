# Agent Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a compile-time-gated channel that lets an external agent read and write content of redin nodes by `:id`, so apps can embed agent-driven UI surfaces.

**Architecture:** A new `:agent :read` / `:agent :edit` attribute on every node type except `:canvas`, paired with a Fennel-side `agent_channel` state slot, three new dev-server endpoints (`/agent/nodes`, `GET/PUT /agent/content/<id>`), and an HTTP-listener gate that starts the server when *either* `--dev` is set *or* `-define:REDIN_AGENT=true` is compiled in. Default builds: zero agent code in the binary.

**Tech Stack:** Odin (host + bridge), Fennel/LuaJIT (runtime), Babashka (UI tests).

**Spec:** `docs/superpowers/specs/2026-05-01-agent-channel-design.md`.

---

## File Structure

**Created:**
- `src/runtime/agent.fnl` — Fennel module: `:event/agent-edit` handler + frame-walking override pass.
- `examples/ai-chat.fnl` — example app demonstrating the channel.
- `test/ui/agent_app.fnl` — UI test app with `:agent :read` / `:edit` nodes.
- `test/ui/test_agent.bb` — UI test suite.

**Modified:**
- `src/redin/bridge/bridge.odin` — listener gate widened to also start when `REDIN_AGENT` compiled.
- `src/redin/bridge/devserver.odin` — three new agent endpoints, gated on `when REDIN_AGENT`.
- `src/runtime/view.fnl` — view tick calls `agent.apply-overrides` between view-fn and flatten.
- `src/runtime/init.fnl` — wires `agent.fnl` install at boot.
- `test/ui/redin_test.bb` — agent helpers (`agent-nodes`, `agent-get-content`, `agent-put-content`).
- `.github/workflows/test.yml` — second build job with `-define:REDIN_AGENT=true`.
- `.github/workflows/release.yml` — extra artifact built with the flag.
- `CLAUDE.md`, `docs/core-api.md`, `docs/reference/dev-server.md`, `docs/reference/elements.md`, `.claude/skills/redin-dev/SKILL.md`, `.claude/skills/redin-maintenance/SKILL.md` — documentation.

---

## Task 1: Compile-time gate constant

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (add the `#config` line at the top)

- [ ] **Step 1: Add the build flag constant**

In `src/redin/bridge/bridge.odin`, just below the `package bridge` line and before the imports, add:

```odin
package bridge

// Compile-time flag enabling the agent channel feature. Default is false;
// set with `odin build ... -define:REDIN_AGENT=true`. When false, the
// agent endpoints, walker, and listener-gate widening all compile out
// to zero bytes.
REDIN_AGENT :: #config(REDIN_AGENT, false)
```

- [ ] **Step 2: Build with default (off)**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success.

- [ ] **Step 3: Build with the flag set**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin-agent
```
Expected: success. (The constant is defined but nothing reads it yet, so the binary is identical except for an unused-constant note.)

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): add REDIN_AGENT compile-time flag

Default false. Subsequent commits gate the agent channel on this flag;
default builds carry zero agent code.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Fennel agent module + view override

**Files:**
- Create: `src/runtime/agent.fnl`
- Create: `test/lua/test_agent.fnl`
- Modify: `src/runtime/init.fnl`
- Modify: `src/runtime/view.fnl`

- [ ] **Step 1: Write the failing Fennel test**

Create `test/lua/test_agent.fnl`:

```fennel
(local dataflow (require :dataflow))
(local agent    (require :agent))

(local t {})

(fn t.test-handler-stores-content []
  (dataflow.init {})
  (agent.install)
  (dataflow.dispatch [:event/agent-edit {:id :reply :content "hello"}])
  (dataflow.flush)
  (assert (= "hello" (. (dataflow.get-state) :agent :reply))
          "agent.reply should be 'hello' after :event/agent-edit"))

(fn t.test-apply-overrides-text []
  ;; A text node tagged :agent :edit with literal "..." should swap to
  ;; the agent_channel value when present.
  (dataflow.init {:agent {:reply "actual"}})
  (let [tree [:text {:id :reply :agent :edit} "..."]
        out  (agent.apply-overrides tree)]
    (assert (= "actual" (. out 3))
            "text content should be replaced when db.agent.reply present")))

(fn t.test-apply-overrides-falls-through []
  ;; Without a db.agent value, the literal stays.
  (dataflow.init {})
  (let [tree [:text {:id :reply :agent :edit} "fallback"]
        out  (agent.apply-overrides tree)]
    (assert (= "fallback" (. out 3))
            "text content should fall through when db.agent.reply missing")))

(fn t.test-apply-overrides-input-value []
  (dataflow.init {:agent {:user-input "typed"}})
  (let [tree [:input {:id :user-input :agent :edit :value "x"}]
        out  (agent.apply-overrides tree)
        attrs (. out 2)]
    (assert (= "typed" (. attrs :value))
            "input :value should be replaced when db.agent.user-input present")))

(fn t.test-apply-overrides-container-children []
  (dataflow.init {:agent {:cards [[:text {} "from agent"]]}})
  (let [tree [:vbox {:id :cards :agent :edit}
                [:text {} "literal child"]]
        out  (agent.apply-overrides tree)]
    (assert (= "from agent" (. (. out 3) 3))
            "vbox children should be replaced when db.agent.cards present")))

(fn t.test-apply-overrides-recurses []
  ;; Nested :agent :edit deeper in the tree should also be replaced.
  (dataflow.init {:agent {:reply "deep"}})
  (let [tree [:vbox {}
                [:text {:id :reply :agent :edit} "..."]]
        out  (agent.apply-overrides tree)
        text-node (. out 3)]
    (assert (= "deep" (. text-node 3))
            "deeply-nested :agent :edit text should be overridden")))

(fn t.test-read-mode-no-override []
  ;; :agent :read does NOT override; the literal stays.
  (dataflow.init {:agent {:reply "ignored"}})
  (let [tree [:text {:id :reply :agent :read} "literal"]
        out  (agent.apply-overrides tree)]
    (assert (= "literal" (. out 3))
            ":agent :read must not override content")))

t
```

- [ ] **Step 2: Run test to verify it fails**

```bash
luajit test/lua/runner.lua test/lua/test_agent.fnl
```
Expected: FAIL — `module 'agent' not found`.

- [ ] **Step 3: Implement `src/runtime/agent.fnl`**

Create `src/runtime/agent.fnl`:

```fennel
;; agent.fnl -- Agent channel runtime.
;;
;; Stores agent-written content in db.agent[id]. Walks the view-fn's
;; output before flattening to swap content of any node tagged
;; `:agent :edit` (with an `:id`) for the value in db.agent[id], if
;; present. `:agent :read` is observe-only -- no override applied.

(local dataflow (require :dataflow))

(local M {})

(local content-attrs
  ;; For these node tags, agent content goes into a specific attr.
  {:input :value :image :src})

(local container-tags
  {:vbox true :hbox true :stack true :popout true :modal true})

(fn handle-edit [db ev]
  (let [payload (. ev 2)
        id (. payload :id)
        content (. payload :content)]
    (dataflow.assoc-in db [:agent id] content)))

(fn M.install []
  (dataflow.reg-handler :event/agent-edit handle-edit))

(fn override-node [node db]
  (when (and (vector? node) (>= (length node) 2))
    (let [tag (. node 1)
          attrs (. node 2)
          id (and (= (type attrs) :table) (. attrs :id))
          mode (and (= (type attrs) :table) (. attrs :agent))
          override (and id (. (or (. db :agent) {}) id))]
      (if (or (not id) (not= mode :edit) (= override nil))
          node
          (let [out (icollect [_ v (ipairs node)] v)]
            (if (. content-attrs tag)
                ;; Swap the named attr (value/src).
                (let [k (. content-attrs tag)
                      new-attrs (collect [ak av (pairs attrs)] ak av)]
                  (tset new-attrs k override)
                  (tset out 2 new-attrs)
                  out)
                (. container-tags tag)
                ;; Replace children: keep [tag attrs], then splice override (a list).
                (let [head [tag attrs]]
                  (each [_ child (ipairs override)]
                    (table.insert head child))
                  head)
                ;; Default: leaf text-like node, swap slot 3.
                (do
                  (tset out 3 override)
                  out)))))))

;; Recursively apply overrides to a frame tree.
(fn walk [node db]
  (if (vector? node)
      (let [overridden (or (override-node node db) node)
            out [(. overridden 1) (. overridden 2)]]
        (for [i 3 (length overridden)]
          (let [child (. overridden i)]
            (table.insert out
              (if (vector? child)
                  (walk child db)
                  child))))
        out)
      node))

(fn M.apply-overrides [tree]
  (let [db (or (dataflow.get-state) {})]
    (walk tree db)))

;; Detect a Fennel-style "vector" -- in Lua/Fennel both are sequential
;; tables with positive-int keys; treat any list-like table as a vector.
(fn vector? [v]
  (and (= (type v) :table)
       (= (type (. v 1)) :string)
       (= (string.sub (. v 1) 1 1) ":")))

(set _G.vector? vector?)

M
```

Note: the `vector?` definition is placed at the bottom intentionally — Fennel's compilation hoists `local`s but not `fn`s declared after their first use. To keep that simple, declare `vector?` *before* `override-node` and `walk`. Restructure:

```fennel
;; Replace the "Detect a vector?" trailer above with this block placed
;; immediately after the `container-tags` local declaration:

(fn vector? [v]
  (and (= (type v) :table)
       (= (type (. v 1)) :string)
       (= (string.sub (. v 1) 1 1) ":")))
```

(I.e. move the `vector?` definition up to just after `container-tags`. The `_G.vector?` line at the bottom is not needed — drop it.)

- [ ] **Step 4: Wire into init.fnl**

Open `src/runtime/init.fnl`. Find where other runtime modules are loaded. Add:

```fennel
(let [agent (require :agent)]
  (agent.install))
```

Place this after `dataflow.init` is available but before `view.render-tick` runs. If you can't find a single deterministic place, add it in the existing module-loading section near where `effect` is loaded.

- [ ] **Step 5: Wire override into view.fnl**

In `src/runtime/view.fnl`, modify `M.render-tick` so the override pass runs between the view-fn return and `frame.flatten`:

Find:
```fennel
(let [result (view-fn)]
  (when result
    (let [flattened (frame.flatten result)]
      ...)))
```

Replace with:
```fennel
(let [result (view-fn)
      result (let [agent (require :agent)] (agent.apply-overrides result))]
  (when result
    (let [flattened (frame.flatten result)]
      ...)))
```

- [ ] **Step 6: Run tests**

```bash
luajit test/lua/runner.lua test/lua/test_agent.fnl
```
Expected: 7 tests pass.

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```
Expected: all 122+7=129 tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/runtime/agent.fnl src/runtime/init.fnl src/runtime/view.fnl test/lua/test_agent.fnl
git commit -m "$(cat <<'EOF'
feat(runtime): agent channel state + frame-tree override

agent.fnl handles :event/agent-edit (stores content in db.agent[id])
and exposes apply-overrides, called by view.render-tick before flatten.
:agent :edit nodes with an :id automatically render db.agent[id] when
present, falling through to literal content otherwise. :agent :read is
observe-only.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Widen HTTP listener gate

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Inspect the current gate**

```bash
grep -n "dev_mode\|devserver_init\|devserver_poll" src/redin/bridge/bridge.odin | head
```
Note the lines where `dev_mode` short-circuits the listener init and poll.

- [ ] **Step 2: Update `init`**

Find the block in `bridge.init` that conditionally starts the dev server (around line 83). Change:

```odin
if dev_mode {
    devserver_init(&b.dev_server, b)
    ...
}
```

to:

```odin
needs_listener := dev_mode
when REDIN_AGENT {
    needs_listener = true
}
if needs_listener {
    devserver_init(&b.dev_server, b)
    ...
}
```

- [ ] **Step 3: Update `poll_devserver`**

Find `poll_devserver` (around line 103):

```odin
poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent, node_rects: []rl.Rectangle) {
    if !b.dev_mode do return
    ...
}
```

Change to:

```odin
poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent, node_rects: []rl.Rectangle) {
    needs_poll := b.dev_mode
    when REDIN_AGENT {
        needs_poll = true
    }
    if !needs_poll do return
    ...
}
```

Audit the rest of the file for other `if !b.dev_mode` short-circuits and apply the same widening:

```bash
grep -n "b.dev_mode" src/redin/bridge/bridge.odin
```
For each hit that controls listener-related behavior (init, poll, hot-reload spawn, shutdown listener), apply the same `when REDIN_AGENT` widening. Hot-reload itself stays gated on `b.dev_mode` only — that's a dev-only feature, not agent.

- [ ] **Step 4: Build with flag off**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success.

- [ ] **Step 5: Build with flag on**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin-agent
```
Expected: success.

- [ ] **Step 6: Smoke test — flag-on binary starts a listener WITHOUT --dev**

```bash
./build/redin-agent test/ui/smoke_app.fnl &
APPPID=$!
sleep 1
ls .redin-port .redin-token 2>&1
PORT=$(cat .redin-port 2>/dev/null); TOKEN=$(cat .redin-token 2>/dev/null)
echo "port=$PORT token=$TOKEN"
# /state should respond if listener is up; even though --dev is off,
# the listener exists for /agent/* support.
curl -sH "Authorization: Bearer $TOKEN" http://localhost:$PORT/state | head -c 200
echo
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Expected: `.redin-port` / `.redin-token` files exist; `/state` returns JSON. (The agent endpoints don't exist yet — Task 4 adds them.)

Note: the dev-only endpoints (e.g. `/state`, `/click`) are still gated on `b.dev_mode` inside `process_request`, so this smoke test relies on `/state` being routed without a dev gate. If `/state` returns 404 in flag-on-no-dev mode, that's expected — the listener is up but routes are gated. In that case, accept "connection succeeded but route 404" as confirmation the listener started.

- [ ] **Step 7: Smoke test — flag-off binary, no --dev: no listener**

```bash
./build/redin test/ui/smoke_app.fnl &
APPPID=$!
sleep 1
ls .redin-port .redin-token 2>&1 | head
kill $APPPID 2>/dev/null
wait $APPPID 2>/dev/null
```
Expected: `.redin-port` and `.redin-token` are NOT created (listener never started).

- [ ] **Step 8: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): widen listener gate to (--dev OR REDIN_AGENT)

The HTTP listener now starts whenever either --dev is set or the
REDIN_AGENT compile flag is true. Existing dev endpoints stay gated
on b.dev_mode inside process_request; this widens only the listener
lifecycle so agent endpoints (next commits) can serve in production
builds compiled with the flag.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `GET /agent/nodes` endpoint (discovery)

**Files:**
- Modify: `src/redin/bridge/devserver.odin`

- [ ] **Step 1: Add a Lua-side walker**

Append to `src/redin/bridge/devserver.odin` (placement: just below the existing `frame_value_to_json` walker around line 710):

```odin
when REDIN_AGENT {

// Walks a Fennel-shaped frame tree DFS and emits a JSON array of
// {id, mode, type} for every node whose attrs include both :agent and :id.
agent_nodes_walker :: proc(b: ^strings.Builder, L: ^Lua_State, index: i32, first: ^bool) {
	idx := index < 0 ? lua_gettop(L) + index + 1 : index
	if !lua_istable(L, idx) do return

	// Detect frame node: [tag-string, attrs-table, ...children]
	lua_rawgeti(L, idx, 1)
	is_node := lua_isstring(L, -1)
	tag := ""
	if is_node {
		tag = string(lua_tostring_raw(L, -1))
		if len(tag) == 0 do is_node = false
	}
	lua_pop(L, 1)
	if !is_node do return

	// attrs at slot 2
	lua_rawgeti(L, idx, 2)
	if lua_istable(L, -1) {
		attrs_idx := lua_gettop(L)
		// :agent
		lua_getfield(L, attrs_idx, "agent")
		mode := ""
		if lua_isstring(L, -1) {
			s := string(lua_tostring_raw(L, -1))
			if s == "read" || s == ":read" do mode = "read"
			if s == "edit" || s == ":edit" do mode = "edit"
		}
		lua_pop(L, 1)
		// :id
		lua_getfield(L, attrs_idx, "id")
		id := ""
		if lua_isstring(L, -1) {
			id = string(lua_tostring_raw(L, -1))
		}
		lua_pop(L, 1)
		if len(mode) > 0 && len(id) > 0 && tag != "canvas" {
			if !first^ do strings.write_string(b, ",")
			first^ = false
			fmt.sbprintf(b, `{"id":"%s","mode":"%s","type":"%s"}`, id, mode, tag)
		}
	}
	lua_pop(L, 1)

	// Recurse into children at slots 3..n
	n := lua_objlen(L, idx)
	for i in 3..=n {
		lua_rawgeti(L, idx, i32(i))
		agent_nodes_walker(b, L, -1, first)
		lua_pop(L, 1)
	}
}

handle_get_agent_nodes :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	L := ds.bridge.L
	lua_getglobal(L, "require")
	lua_pushstring(L, "view")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	lua_getfield(L, -1, "get-last-push")
	lua_remove(L, -2)
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "[")
	first := true
	agent_nodes_walker(&b, L, -1, &first)
	strings.write_string(&b, "]")
	lua_pop(L, 1)
	respond_json(ch, strings.to_string(b))
}

} // when REDIN_AGENT
```

- [ ] **Step 2: Wire the route**

In `process_request`'s `case "GET":` block, add (gated):

```odin
when REDIN_AGENT {
    } else if req.path == "/agent/nodes" {
        handle_get_agent_nodes(ds, ch)
}
```

Note: Odin's `when` and `else if` chains can be tricky to compose. If the above causes a parse error, replace with a separate `when REDIN_AGENT { ... }` block higher in the chain that handles the agent paths and falls through:

```odin
case "GET":
    handled := false
    when REDIN_AGENT {
        if req.path == "/agent/nodes" {
            handle_get_agent_nodes(ds, ch)
            handled = true
        }
    }
    if !handled {
        if req.path == "/frames" {
            handle_get_frames(ds, ch)
        } else if ...existing chain... {
            ...
        } else {
            respond_text(ch, 404, "Not found")
        }
    }
```

Pick whichever compiles cleanly. Audit the resulting code path for `--dev` mode to ensure existing routes still respond.

- [ ] **Step 3: Build with flag**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin-agent
```
Expected: success.

- [ ] **Step 4: Smoke test against drag_app**

The drag app already has `:id` attrs (e.g. `:item-1`). It does not yet have `:agent`. So `/agent/nodes` should return `[]`.

```bash
./build/redin-agent --dev test/ui/drag_app.fnl &
APPPID=$!
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"
curl -sH "$H" http://localhost:$PORT/agent/nodes
echo
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Expected: `[]` (empty array, since no node has `:agent`).

- [ ] **Step 5: Build flag-off and confirm 404**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
./build/redin --dev test/ui/drag_app.fnl &
APPPID=$!
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"
curl -sH "$H" -i http://localhost:$PORT/agent/nodes | head -1
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Expected: `HTTP/1.1 404 Not Found` (route not compiled in).

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(devserver): GET /agent/nodes (discovery)

When REDIN_AGENT is compiled, lists every node in the current frame
whose attrs include both :agent (:read or :edit) and :id. :canvas is
excluded. Without the flag the route returns 404.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `GET /agent/content/<id>` endpoint

**Files:**
- Modify: `src/redin/bridge/devserver.odin`

- [ ] **Step 1: Add a find-by-id helper + content extractor**

Append in the same `when REDIN_AGENT { ... }` block as Task 4:

```odin
// Walk the frame tree, push the matching [tag attrs ...children] table
// onto the Lua stack at -1 if found and return true. Otherwise leaves
// the stack as it was and returns false. Caller must lua_pop(L, 1) on success.
agent_find_by_id :: proc(L: ^Lua_State, index: i32, target_id: string) -> bool {
	idx := index < 0 ? lua_gettop(L) + index + 1 : index
	if !lua_istable(L, idx) do return false

	// Inspect tag + id+agent at attrs.
	lua_rawgeti(L, idx, 1)
	is_node := lua_isstring(L, -1)
	lua_pop(L, 1)
	if is_node {
		lua_rawgeti(L, idx, 2)
		if lua_istable(L, -1) {
			lua_getfield(L, -1, "id")
			id := ""
			if lua_isstring(L, -1) do id = string(lua_tostring_raw(L, -1))
			lua_pop(L, 1)
			lua_pop(L, 1) // attrs
			if id == target_id {
				// Push the node table again so caller has it at -1.
				lua_pushvalue(L, idx)
				return true
			}
		} else {
			lua_pop(L, 1)
		}
	}

	// Recurse into children.
	n := lua_objlen(L, idx)
	for i in 3..=n {
		lua_rawgeti(L, idx, i32(i))
		if agent_find_by_id(L, -1, target_id) {
			// Move the found node up by 1 (replacing the child we pushed).
			lua_remove(L, -2)
			return true
		}
		lua_pop(L, 1)
	}
	return false
}

// Reads attr field from a node table at -1 and returns its string value.
agent_node_attr_string :: proc(L: ^Lua_State, attr: cstring) -> string {
	if !lua_istable(L, -1) do return ""
	lua_rawgeti(L, -1, 2)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return ""
	lua_getfield(L, -1, attr)
	defer lua_pop(L, 1)
	if !lua_isstring(L, -1) do return ""
	return strings.clone(string(lua_tostring_raw(L, -1)), context.temp_allocator)
}

agent_node_tag :: proc(L: ^Lua_State) -> string {
	if !lua_istable(L, -1) do return ""
	lua_rawgeti(L, -1, 1)
	defer lua_pop(L, 1)
	if !lua_isstring(L, -1) do return ""
	return strings.clone(string(lua_tostring_raw(L, -1)), context.temp_allocator)
}

// Emits {"content": ...} JSON for the node at -1 based on its tag.
emit_agent_content :: proc(b: ^strings.Builder, L: ^Lua_State, tag: string) {
	strings.write_string(b, `{"content":`)
	switch tag {
	case "input":
		// Value lives in attrs.value.
		val := agent_node_attr_string(L, "value")
		fmt.sbprintf(b, `"%s"`, escape_json_string(val))
	case "image":
		val := agent_node_attr_string(L, "src")
		fmt.sbprintf(b, `"%s"`, escape_json_string(val))
	case "vbox", "hbox", "stack", "popout", "modal":
		// Emit children as JSON array (use existing lua_value_to_json for each child).
		strings.write_string(b, "[")
		n := lua_objlen(L, -1)
		first := true
		for i in 3..=n {
			lua_rawgeti(L, -1, i32(i))
			if !first do strings.write_string(b, ",")
			first = false
			lua_value_to_json(b, L, -1)
			lua_pop(L, 1)
		}
		strings.write_string(b, "]")
	case:
		// Default: leaf-text-like (text, button). Content is slot [3].
		lua_rawgeti(L, -1, 3)
		val := ""
		if lua_isstring(L, -1) do val = string(lua_tostring_raw(L, -1))
		lua_pop(L, 1)
		fmt.sbprintf(b, `"%s"`, escape_json_string(val))
	}
	strings.write_string(b, "}")
}

// Quick JSON string escaper for content values. Same approach as the
// existing lua_value_to_json's string emitter -- if a helper is already
// present, use it instead.
escape_json_string :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\t': strings.write_string(&b, `\t`)
		case:      strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

handle_get_agent_content :: proc(ds: ^Dev_Server, ch: ^Response_Channel, id: string) {
	L := ds.bridge.L
	// Get last frame.
	lua_getglobal(L, "require")
	lua_pushstring(L, "view")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	lua_getfield(L, -1, "get-last-push")
	lua_remove(L, -2)
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	defer lua_pop(L, 1) // last-push table

	if !agent_find_by_id(L, -1, id) {
		respond_json_error(ch, 404, `{"error":"id not found"}`)
		return
	}
	defer lua_pop(L, 1) // found node

	tag := agent_node_tag(L)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	emit_agent_content(&b, L, tag)
	respond_json(ch, strings.to_string(b))
}
```

If `escape_json_string` collides with an existing helper in `json.odin`, drop this copy and use the existing one.

- [ ] **Step 2: Wire the route**

In `process_request`'s `case "GET":`, add (in the agent-handled block from Task 4):

```odin
when REDIN_AGENT {
    if strings.has_prefix(req.path, "/agent/content/") {
        handle_get_agent_content(ds, ch, req.path[len("/agent/content/"):])
        handled = true
    }
    ...existing /agent/nodes arm...
}
```

- [ ] **Step 3: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin-agent
```
Expected: success.

- [ ] **Step 4: Smoke test**

Use a temporary test app (write inline):

```bash
cat > /tmp/agent_smoke.fnl <<'EOF'
(local dataflow (require :dataflow))
(dataflow.init {})
(fn _G.main_view []
  [:vbox {}
    [:text  {:id :reply :agent :edit} "default"]
    [:input {:id :user-input :agent :read :value "typed-here"}]])
EOF

./build/redin-agent --dev /tmp/agent_smoke.fnl &
APPPID=$!
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"

echo "--- nodes ---"
curl -sH "$H" http://localhost:$PORT/agent/nodes
echo
echo "--- text content ---"
curl -sH "$H" http://localhost:$PORT/agent/content/reply
echo
echo "--- input content ---"
curl -sH "$H" http://localhost:$PORT/agent/content/user-input
echo
echo "--- missing id ---"
curl -sH "$H" -i http://localhost:$PORT/agent/content/nope | head -1

curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```

Expected:
```
--- nodes ---
[{"id":"reply","mode":"edit","type":"text"},{"id":"user-input","mode":"read","type":"input"}]
--- text content ---
{"content":"default"}
--- input content ---
{"content":"typed-here"}
--- missing id ---
HTTP/1.1 404 Not Found
```

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(devserver): GET /agent/content/<id>

Reads node content by id. Per-tag semantics: text/button slot 3,
input attrs.value, image attrs.src, container nodes return their
children list as a JSON array. 404 when id missing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `PUT /agent/content/<id>` endpoint

**Files:**
- Modify: `src/redin/bridge/devserver.odin`

- [ ] **Step 1: Add the handler**

Append in the `when REDIN_AGENT { ... }` block:

```odin
handle_put_agent_content :: proc(ds: ^Dev_Server, ch: ^Response_Channel, id: string, body: string) {
	L := ds.bridge.L

	// 1. Decode body and stage at -1.
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1) // decoded body
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object with content"}`)
		return
	}
	lua_getfield(L, -1, "content")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		respond_json_error(ch, 400, `{"error":"missing content field"}`)
		return
	}
	// content is now at -1; we keep it on stack for later marshaling.
	body_idx := lua_gettop(L)

	// 2. Find the target node and validate.
	lua_getglobal(L, "require")
	lua_pushstring(L, "view")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	lua_getfield(L, -1, "get-last-push")
	lua_remove(L, -2)
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	defer lua_pop(L, 1) // last-push table

	if !agent_find_by_id(L, -1, id) {
		respond_json_error(ch, 404, `{"error":"id not found"}`)
		return
	}
	defer lua_pop(L, 1) // found node

	// 3. Read mode + tag.
	tag := agent_node_tag(L)
	mode := agent_node_attr_string(L, "agent")
	if mode != "edit" && mode != ":edit" {
		respond_json_error(ch, 403, `{"error":"node is not :agent :edit"}`)
		return
	}

	// 4. Validate body shape against tag.
	is_container := tag == "vbox" || tag == "hbox" || tag == "stack" ||
	                tag == "popout" || tag == "modal"
	if is_container {
		if !lua_istable(L, body_idx) {
			respond_json_error(ch, 400, `{"error":"container content must be an array"}`)
			return
		}
	} else {
		if !lua_isstring(L, body_idx) {
			respond_json_error(ch, 400, `{"error":"leaf content must be a string"}`)
			return
		}
	}

	// 5. Build the dispatched event: [:dispatch [:event/agent-edit {:id id :content <body>}]]
	// Reuse the existing event_queue path: enqueue a Dispatch_Event that the
	// runtime delivers next frame. We push a Lua table mirroring the
	// expected shape, then call dataflow.dispatch directly.
	lua_getglobal(L, "require")
	lua_pushstring(L, "dataflow")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error: dataflow"}`)
		return
	}
	lua_getfield(L, -1, "dispatch")
	lua_remove(L, -2)
	// Build the [:event/agent-edit {:id ... :content <body_idx>}] vector.
	lua_createtable(L, 2, 0)
	ev_idx := lua_gettop(L)
	lua_pushstring(L, "event/agent-edit")
	lua_rawseti(L, ev_idx, 1)
	lua_createtable(L, 0, 2)
	payload_idx := lua_gettop(L)
	lua_pushstring(L, cstring(raw_data(id)), uint(len(id)))
	lua_setfield(L, payload_idx, "id")
	lua_pushvalue(L, body_idx) // copy of decoded content
	lua_setfield(L, payload_idx, "content")
	lua_rawseti(L, ev_idx, 2)
	// dispatch(...) pops one arg.
	if lua_pcall(L, 1, 0, 0) != 0 {
		respond_json_error(ch, 500, `{"error":"dispatch failed"}`)
		return
	}
	respond_json_ok(ch)
}
```

- [ ] **Step 2: Wire the route**

In `process_request`'s `case "PUT":`, add (gated):

```odin
when REDIN_AGENT {
    if strings.has_prefix(req.path, "/agent/content/") {
        handle_put_agent_content(ds, ch, req.path[len("/agent/content/"):], req.body)
    } else if ...existing /aspects... {
        ...
    }
}
```

- [ ] **Step 3: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin-agent
```

- [ ] **Step 4: Smoke test all paths**

```bash
./build/redin-agent --dev /tmp/agent_smoke.fnl &
APPPID=$!
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"

echo "--- PUT to :edit text (expect ok) ---"
curl -sH "$H" -X PUT -d '{"content":"hello world"}' http://localhost:$PORT/agent/content/reply

echo
echo "--- GET should now reflect the agent write ---"
sleep 0.3
curl -sH "$H" http://localhost:$PORT/state/agent.reply
echo

echo "--- PUT to :read input (expect 403) ---"
curl -sH "$H" -X PUT -d '{"content":"x"}' http://localhost:$PORT/agent/content/user-input

echo
echo "--- PUT array to a text node (expect 400) ---"
curl -sH "$H" -X PUT -d '{"content":[1,2,3]}' http://localhost:$PORT/agent/content/reply

echo
echo "--- PUT to missing id (expect 404) ---"
curl -sH "$H" -X PUT -d '{"content":"x"}' http://localhost:$PORT/agent/content/nope

echo
echo "--- PUT missing content (expect 400) ---"
curl -sH "$H" -X PUT -d '{}' http://localhost:$PORT/agent/content/reply

curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```

Expected output:
- First PUT: `{"ok":true}`
- `/state/agent.reply`: `"hello world"`
- Read PUT: `{"error":"node is not :agent :edit"}` with HTTP 403
- Array PUT: `{"error":"leaf content must be a string"}` with HTTP 400
- Missing id: `{"error":"id not found"}` with HTTP 404
- Missing content: `{"error":"missing content field"}` with HTTP 400

- [ ] **Step 5: Container write smoke test**

```bash
cat > /tmp/agent_container.fnl <<'EOF'
(local dataflow (require :dataflow))
(dataflow.init {})
(fn _G.main_view []
  [:vbox {:id :region :agent :edit}
    [:text {} "default"]])
EOF

./build/redin-agent --dev /tmp/agent_container.fnl &
APPPID=$!
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"

echo "--- PUT children list to container ---"
curl -sH "$H" -X PUT \
  -d '{"content":[["text",{"aspect":"row"},"agent-posted-row"]]}' \
  http://localhost:$PORT/agent/content/region

sleep 0.3
echo
echo "--- frames should now show the new child ---"
curl -sH "$H" http://localhost:$PORT/frames | head -c 300

curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Expected: `{"ok":true}` then frames JSON containing `"agent-posted-row"`.

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(devserver): PUT /agent/content/<id>

Validates node exists, mode is :edit, body shape matches tag. On
success dispatches :event/agent-edit to the dataflow; the Fennel
handler stores it in db.agent[id]. Returns 404/403/400 for the
respective error paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Example app + UI test app

**Files:**
- Create: `examples/ai-chat.fnl`
- Create: `test/ui/agent_app.fnl`

- [ ] **Step 1: Create the example**

Create `examples/ai-chat.fnl`:

```fennel
;; AI chat example — requires a build with -define:REDIN_AGENT=true.
;; Markdown rendering for the agent's reply is tracked in issue #100;
;; for now the reply renders as plain text.

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

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:text  {:id :reply :agent :edit :aspect :agent-bubble} "…"]
    [:input {:id :user-input :agent :read :aspect :user-input
             :value (subscribe :sub/typed)
             :change :event/typed
             :submit :event/submitted}
            ""]])
```

- [ ] **Step 2: Create the test app**

Create `test/ui/agent_app.fnl`:

```fennel
;; UI test app for /agent/* endpoints. Needs -define:REDIN_AGENT=true
;; to be useful; the test runner skips agent tests when the flag is off.

(local dataflow (require :dataflow))

(dataflow.init {:typed ""})

(reg-handler :event/typed (fn [db ev] (assoc db :typed (. ev :value))))
(reg-sub     :sub/typed   (fn [db] (db :typed)))

(fn _G.main_view []
  [:vbox {:id :root}
    [:text  {:id :reply       :agent :edit} "default-reply"]
    [:text  {:id :ro-text     :agent :read} "read-only-text"]
    [:input {:id :user-input  :agent :read
             :value (subscribe :sub/typed)
             :change :event/typed} ""]
    [:button {:id :ro-button  :agent :read} "click me"]
    [:vbox  {:id :region      :agent :edit}
      [:text {} "default-child"]]])
```

- [ ] **Step 3: Confirm it boots**

```bash
./build/redin-agent --dev test/ui/agent_app.fnl &
APPPID=$!
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"
curl -sH "$H" http://localhost:$PORT/agent/nodes
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```

Expected: a list of 5 nodes (`reply`, `ro-text`, `user-input`, `ro-button`, `region`).

- [ ] **Step 4: Commit**

```bash
git add examples/ai-chat.fnl test/ui/agent_app.fnl
git commit -m "$(cat <<'EOF'
example(agent): ai-chat + agent_app test fixtures

ai-chat showcases :agent :edit on a reply text and :read on the user
input. agent_app exercises every supported node type (text, input,
button, container) with both read and edit modes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: bb test helpers + UI test suite

**Files:**
- Modify: `test/ui/redin_test.bb`
- Create: `test/ui/test_agent.bb`

- [ ] **Step 1: Add helpers**

Open `test/ui/redin_test.bb`. Find a coherent insertion point (after the input-takeover block from earlier work). Add:

```clojure
;; ---------------------------------------------------------------------------
;; Agent channel (only meaningful when binary built with -define:REDIN_AGENT=true)
;; ---------------------------------------------------------------------------

(defn agent-supported?
  "Returns true if the binary exposes the agent endpoints."
  []
  (let [resp (try (http/get (str (base-url) "/agent/nodes")
                           {:headers (auth-headers) :throw false})
                  (catch Exception _ {:status 0}))]
    (= 200 (:status resp))))

(defn agent-nodes [] (get-json "/agent/nodes"))

(defn agent-get-content [id]
  (get-json (str "/agent/content/" (name id))))

(defn agent-put-content
  "Body is {:content <string-or-vector>}."
  [id body]
  (let [resp (http/put (str (base-url) "/agent/content/" (name id))
                       {:headers (merge {"Content-Type" "application/json"}
                                        (auth-headers))
                        :body (json/generate-string body)
                        :throw false})]
    {:status (:status resp)
     :body (try (json/parse-string (:body resp) true)
                (catch Exception _ (:body resp)))}))
```

- [ ] **Step 2: Create the test suite**

Create `test/ui/test_agent.bb`:

```clojure
(require '[redin-test :refer :all])

(when-not (agent-supported?)
  (println "[skip] /agent/* not compiled in (need -define:REDIN_AGENT=true)")
  (System/exit 0))

;; -- Discovery --

(deftest agent-nodes-discovers-tagged-nodes
  (let [nodes (agent-nodes)
        ids (set (map :id nodes))]
    (assert (contains? ids "reply")       "reply present")
    (assert (contains? ids "user-input")  "user-input present")
    (assert (contains? ids "ro-text")     "ro-text present")
    (assert (contains? ids "region")      "region present")))

(deftest agent-nodes-marks-modes
  (let [nodes (agent-nodes)
        by-id (into {} (map (juxt :id :mode) nodes))]
    (assert (= "edit" (by-id "reply"))      "reply is :edit")
    (assert (= "read" (by-id "user-input")) "user-input is :read")
    (assert (= "edit" (by-id "region"))     "region is :edit")))

;; -- GET --

(deftest agent-get-text
  (let [r (agent-get-content :reply)]
    (assert (= "default-reply" (:content r))
            (str "expected default-reply, got " (:content r)))))

(deftest agent-get-input-value
  (dispatch ["event/typed" {:value "abc"}])
  (wait-ms 100)
  (let [r (agent-get-content :user-input)]
    (assert (= "abc" (:content r)) (str "got " (:content r)))))

(deftest agent-get-missing-id-404
  (let [resp (http/get (str (base-url) "/agent/content/no-such")
                       {:headers (auth-headers) :throw false})]
    (assert (= 404 (:status resp)) (str "expected 404, got " (:status resp)))))

;; -- PUT --

(deftest agent-put-text-replaces-content
  (let [resp (agent-put-content :reply {:content "from-agent"})]
    (assert (= 200 (:status resp))))
  (wait-ms 200)
  ;; The agent_channel is exposed at db.agent[id].
  (assert-state "agent.reply" #(= % "from-agent")
                "db.agent.reply should reflect the PUT"))

(deftest agent-put-read-mode-403
  (let [resp (agent-put-content :user-input {:content "x"})]
    (assert (= 403 (:status resp))
            (str "expected 403, got " (:status resp)))))

(deftest agent-put-wrong-shape-400
  (let [resp (agent-put-content :reply {:content [1 2]})]
    (assert (= 400 (:status resp))
            (str "expected 400 for array body to text node, got " (:status resp)))))

(deftest agent-put-container-replaces-children
  (let [resp (agent-put-content :region
               {:content [["text" {} "agent-row-1"]
                          ["text" {} "agent-row-2"]]})]
    (assert (= 200 (:status resp))))
  (wait-ms 200)
  ;; Verify in /frames that the region's children include the new texts.
  (let [frame-json (get-json "/frames")
        flat (pr-str frame-json)]
    (assert (re-find #"agent-row-1" flat) "region should now contain agent-row-1")))
```

- [ ] **Step 3: Run the suite**

```bash
./build/redin-agent --dev test/ui/agent_app.fnl &
APPPID=$!
sleep 2
bb test/ui/run.bb test/ui/test_agent.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Expected: 9/9 pass.

- [ ] **Step 4: Confirm skip behavior with flag-off binary**

```bash
./build/redin --dev test/ui/agent_app.fnl &
APPPID=$!
sleep 2
bb test/ui/run.bb test/ui/test_agent.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Expected: prints `[skip] /agent/* not compiled in ...` and exits 0.

- [ ] **Step 5: Commit**

```bash
git add test/ui/redin_test.bb test/ui/test_agent.bb
git commit -m "$(cat <<'EOF'
test(ui): agent channel test helpers + suite

agent-supported? probes the binary for the compile flag and exits
cleanly when the suite isn't applicable. Covers discovery, GET on
text/input, PUT on text/container, 403/404/400 error paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: CI build matrix

**Files:**
- Modify: `.github/workflows/test.yml`

- [ ] **Step 1: Add a second build job**

Open `.github/workflows/test.yml`. After the existing `test:` job, add a sibling job:

```yaml
  test-agent:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y luajit libssl-dev xvfb \
            libgl1-mesa-dev libx11-dev libxrandr-dev libxi-dev \
            libxcursor-dev libxinerama-dev
      - name: Install Odin
        uses: laytan/setup-odin@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
      - name: Install Babashka
        run: curl -sL https://raw.githubusercontent.com/babashka/babashka/master/install | sudo bash
      - name: Run Fennel tests
        run: luajit test/lua/runner.lua test/lua/test_*.fnl
      - name: Build redin (agent flag on)
        run: |
          mkdir -p build
          odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit \
            -define:REDIN_AGENT=true -out:build/redin
      - name: Run UI tests under xvfb (includes agent suite)
        run: bash test/ui/run-all.sh --headless
```

The `test/ui/run-all.sh` script discovers `test_agent.bb` automatically. With the agent flag on, the suite runs; with it off (in the original `test:` job, which doesn't currently run UI tests), the suite skips itself.

If `run-all.sh` doesn't currently run in the default `test:` job, leave that alone — this new job is the agent-build coverage.

- [ ] **Step 2: Validate locally with `act` or by inspecting the YAML**

```bash
# Lint with yq if available, or just visually inspect.
yq '.' .github/workflows/test.yml | head -60
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "$(cat <<'EOF'
ci: add test-agent job that builds with REDIN_AGENT=true

Guards against the agent code bit-rotting silently. The default test
job stays unchanged; this new job builds with the flag and runs the
UI test suite under xvfb (agent suite included).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Release packaging

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Add an agent-flagged second build, packaging, and upload**

Open `.github/workflows/release.yml`. The existing build job has these steps in order:
1. Build release binary (`-out:build/redin -o:speed`)
2. AOT compile Fennel runtime → `dist/runtime/*.lua`
3. Package release → assembles `dist/`, tarballs to `redin-${VERSION}-linux-amd64.tar.gz`
4. Smoke check via `scripts/smoke-native.sh`
5. Upload artifact

After step 5 (the `Upload artifact` step), add three new steps that build the agent flavor and package it into a separate `dist-agent/`:

```yaml
      - name: Build agent binary
        run: |
          rm -rf dist-agent
          mkdir -p dist-agent
          odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit \
            -define:REDIN_AGENT=true -out:dist-agent/redin -o:speed

      - name: Package agent release
        env:
          VERSION: ${{ steps.version.outputs.tag }}
        run: |
          # Mirror the structure of the default `dist/` directory but with the
          # agent binary swapped in. Other files (runtime, lib, vendor, docs,
          # skills, LICENSE) are identical to the default build, so we copy
          # them from `dist/` rather than re-running the bundling steps.
          cp -r dist/runtime dist-agent/
          cp -r dist/lib dist-agent/
          cp -r dist/vendor dist-agent/
          cp -r dist/docs dist-agent/
          cp -r dist/skills dist-agent/
          [ -f dist/LICENSE ] && cp dist/LICENSE dist-agent/ || true
          tar czf "redin-${VERSION}-agent-linux-amd64.tar.gz" -C dist-agent .

      - name: Upload agent artifact
        uses: actions/upload-artifact@v7
        with:
          name: redin-${{ steps.version.outputs.tag }}-agent-linux-amd64
          path: redin-${{ steps.version.outputs.tag }}-agent-linux-amd64.tar.gz
```

The existing `Smoke check` step (`scripts/smoke-native.sh`) runs against the default tarball only — that's fine; we don't need a second smoke check for the agent build (it's the same code path with one extra optional feature).

The `release` job uses `files: artifacts/**/*.tar.gz` which already matches both tarballs — no change needed there.

- [ ] **Step 2: Inspect locally**

```bash
yq '.' .github/workflows/release.yml | head -120
```

Verify the new steps appear after the original `Upload artifact` step and use `dist-agent/` consistently.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "$(cat <<'EOF'
release: build an extra agent-enabled artifact per release

Default release tarball stays agent-free. A second tarball
(redin-vX.Y.Z-agent-linux-amd64.tar.gz) ships with REDIN_AGENT=true,
exposing the /agent/* endpoints. Users pick.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Documentation

**Files:**
- Modify: `CLAUDE.md`, `docs/core-api.md`, `docs/reference/dev-server.md`, `docs/reference/elements.md`, `.claude/skills/redin-dev/SKILL.md`, `.claude/skills/redin-maintenance/SKILL.md`

- [ ] **Step 1: CLAUDE.md**

Add to the build section a note about the optional flag:

```markdown
## Building (default)

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

## Building with the agent channel

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit \
    -define:REDIN_AGENT=true -out:build/redin
```

When `REDIN_AGENT` is set, the dev-server listener starts in any run
(not just `--dev`) and exposes the `/agent/*` endpoints. Default
release builds carry zero agent code.
```

In the dev-server endpoint table, add:

```markdown
| `GET`  | `/agent/nodes` | List `:agent`-tagged nodes (REDIN_AGENT only). |
| `GET`  | `/agent/content/<id>` | Read content (REDIN_AGENT only). |
| `PUT`  | `/agent/content/<id>` | Write content; node must be `:agent :edit` (REDIN_AGENT only). |
```

- [ ] **Step 2: docs/core-api.md**

Add an "Agent channel" subsection under the dev-server section, summarising:
- The compile-time flag.
- The `:agent :read` / `:agent :edit` attribute.
- Per-node-type content semantics (small table).
- The three endpoints with body shapes.
- A worked curl example for a write.

- [ ] **Step 3: docs/reference/dev-server.md**

Add the three endpoints with examples. Include the worked write example (text and container).

- [ ] **Step 4: docs/reference/elements.md**

For each element table (text, input, button, image, vbox, hbox, stack, popout, modal), add a row noting the `:agent` attribute. Canvas docs note that `:agent` is rejected.

- [ ] **Step 5: .claude/skills/redin-dev/SKILL.md**

Add the build flag, attribute, and endpoint summary.

- [ ] **Step 6: .claude/skills/redin-maintenance/SKILL.md**

Add `REDIN_AGENT` to the verification matrix:
- A new row noting that `odin build ... -define:REDIN_AGENT=true` is part of the build matrix.
- A note that `test/ui/test_agent.bb` skips itself when the flag is off.

- [ ] **Step 7: Verify**

```bash
rg -n 'REDIN_AGENT|/agent/(nodes|content)' docs/ .claude/skills/ CLAUDE.md
```
Expected: hits in every file listed above.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md docs/core-api.md docs/reference/dev-server.md docs/reference/elements.md .claude/skills/redin-dev/SKILL.md .claude/skills/redin-maintenance/SKILL.md
git commit -m "$(cat <<'EOF'
docs: agent channel attribute, endpoints, and build flag

Update CLAUDE.md, core-api, dev-server reference, elements reference,
and the redin-dev / redin-maintenance skills with the new :agent
attribute and /agent/* endpoints.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Final verification

- [ ] **Step 1: Build flag-off (default)**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success.

- [ ] **Step 2: Build flag-on**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -define:REDIN_AGENT=true -out:build/redin-agent
```
Expected: success.

- [ ] **Step 3: Fennel runtime tests**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```
Expected: 129/129 (122 existing + 7 agent).

- [ ] **Step 4: Odin parser + input tests**

```bash
odin test src/redin/parser
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```
Expected: all pass.

- [ ] **Step 5: Full UI suite (flag-off)**

```bash
bash test/ui/run-all.sh --headless
```
Expected: all suites pass; agent suite skips with the `[skip]` message.

- [ ] **Step 6: Full UI suite (flag-on)**

Update the run-all script to use the agent binary (or run the suite manually with the flag-on binary):

```bash
# Quick manual approach: replace build/redin with the agent build for this run.
cp build/redin-agent build/redin
bash test/ui/run-all.sh --headless
# Restore default afterwards if you care.
```
Expected: all suites pass including the new `test_agent.bb` (9 tests).

- [ ] **Step 7: Memory check**

```bash
./build/redin-agent --track-mem test/ui/agent_app.fnl &
APPPID=$!
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"
curl -sH "$H" -X PUT -d '{"content":"check"}' http://localhost:$PORT/agent/content/reply
sleep 0.3
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait $APPPID 2>/dev/null
```
Inspect the binary's stderr for `leak` / `outstanding` lines. Expected: none.

- [ ] **Step 8: No commit (verification only)**

---

## Self-review checklist

- Spec coverage:
  - REDIN_AGENT compile flag → Task 1
  - `:agent :read` / `:edit` attribute parsing → Task 2 (Fennel-side, not stored on Odin Node — simpler than spec; functionally equivalent)
  - `agent_channel` storage + view override → Task 2
  - Listener gate widening → Task 3
  - `/agent/nodes` → Task 4
  - `GET /agent/content/<id>` → Task 5
  - `PUT /agent/content/<id>` → Task 6
  - Per-node-type content semantics → Tasks 5/6
  - Container subtree write → Task 6
  - Example app + UI test app → Task 7
  - UI test suite → Task 8
  - CI matrix → Task 9
  - Release packaging → Task 10
  - Documentation → Task 11
  - Verification → Task 12
- Placeholder scan: no "TBD"/"TODO"/"add appropriate" patterns.
- Type consistency: `agent_channel` (Fennel `db.agent`), `Agent_Mode` enum, `:event/agent-edit`, helper proc names (`agent_find_by_id`, `agent_node_tag`, `agent_node_attr_string`, `emit_agent_content`) — used consistently.
- Note: the spec proposed adding an `Agent_Mode` field to every Odin Node struct. The plan implements equivalent behavior by reading `:agent` from the Lua attrs at endpoint time + Fennel-side override evaluation. Functionally equivalent, smaller diff, fewer Odin types touched.
