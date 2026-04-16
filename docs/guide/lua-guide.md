# Writing redin apps in Lua

Fennel is the default language for redin, but it compiles to Lua 5.1 and the entire
runtime is available in plain Lua. All app-level globals are registered with underscored
names. No Fennel required.

## API name mapping

The runtime exposes every function under both its Fennel (hyphenated) name and its Lua
(underscored) name. Either works from Fennel; only the underscored names are valid Lua
identifiers.

| Fennel name   | Lua name      | Purpose                        |
| ------------- | ------------- | ------------------------------ |
| `reg-handler` | `reg_handler` | Register an event handler      |
| `reg-sub`     | `reg_sub`     | Register a subscription        |
| `get-in`      | `get_in`      | Tracked nested state read      |
| `assoc-in`    | `assoc_in`    | Tracked nested state write     |
| `update-in`   | `update_in`   | Tracked nested state update    |
| `dissoc-in`   | `dissoc_in`   | Tracked nested state remove    |
| `dispatch`    | `dispatch`    | Dispatch an event (same name)  |
| `subscribe`   | `subscribe`   | Read a subscription (same name)|
| `reg-fx`      | `reg_fx`      | Register an effect executor    |

`get`, `assoc`, `update`, `dissoc`, and `register` are valid Lua identifiers and are
registered under those names directly.

---

## Counter app

A complete counter app written in pure Lua:

```lua
-- counter.lua

local dataflow = require("dataflow")
local theme_mod = require("theme")

-- 1. Set a Nord theme
theme_mod.set_theme({
  surface        = {bg = {46, 52, 64}, padding = {24, 24, 24, 24}},
  heading        = {color = {216, 222, 233}, font_size = 32, weight = 1},
  button         = {bg = {76, 86, 106}, color = {236, 239, 244},
                    radius = 6, padding = {10, 20, 10, 20}},
  ["button#hover"] = {bg = {94, 105, 126}},
})

-- 2. Initialize app state
dataflow.init({counter = 0})

-- 3. Register an event handler
reg_handler("event/inc", function(db, event)
  return update(db, "counter", function(n) return n + 1 end)
end)

-- 4. Register a subscription
reg_sub("sub/counter", function(db)
  return get(db, "counter")
end)

-- 5. Define the view
function main_view()
  local count = subscribe("sub/counter")
  return {
    frame = {"vbox", {aspect = "surface"},
      {"text", {aspect = "heading"}, tostring(count)},
      {"button", {aspect = "button", click = {"event/inc"}}, "+1"}},
    bind = {}
  }
end
```

The runtime calls `main_view` (the global) on each render tick. The returned table must
have `frame` and `bind` keys.

---

## Key Lua differences from Fennel

### String keys, not keywords

Fennel uses `:keyword` syntax as a shorthand for strings. In Lua, use plain strings.

```fennel
(assoc db :filter "all")
```

```lua
assoc(db, "filter", "all")
```

### 1-indexed arrays

Lua tables are 1-indexed. The redin path system uses the same indexing as Lua -- paths
that index into arrays are 1-indexed.

```lua
-- Read the first item's done flag
get_in(db, {"items", 1, "done"})

-- Toggle it
update_in(db, {"items", 1, "done"}, function(v) return not v end)
```

### Table constructors

Fennel distinguishes `{:k v}` (map) from `[:a :b]` (array) with different syntax. In Lua
both use `{}`. Maps use `key = value`; arrays use positional values.

```lua
-- Map
{padding = 24, width = 200}

-- Array / frame node
{"vbox", {}, {"text", {}, "hello"}}
```

### Event vectors

Events are plain arrays. The first element is the event name string.

```lua
dispatch({"event/inc"})
dispatch({"event/add-todo", "Buy milk"})
```

### State variant aspects

Theme keys with `#` (e.g. `button#hover`) must use bracket syntax in Lua table
constructors because `#` is not valid in bare keys:

```lua
theme_mod.set_theme({
  button               = {bg = {76, 86, 106}},
  ["button#hover"]     = {bg = {94, 105, 126}},
  ["button#active"]    = {bg = {59, 66, 82}},
})
```

---

## Todo app

A more complete example with add and list display:

```lua
-- todo.lua

local dataflow = require("dataflow")
local theme_mod = require("theme")

theme_mod.set_theme({
  surface          = {bg = {46, 52, 64}, padding = {24, 24, 24, 24}},
  heading          = {font_size = 24, color = {236, 239, 244}, weight = 1},
  body             = {font_size = 14, color = {216, 222, 233}},
  muted            = {font_size = 13, color = {76, 86, 106}},
  input            = {bg = {59, 66, 82}, color = {236, 239, 244},
                      border = {76, 86, 106}, border_width = 1,
                      radius = 4, padding = {8, 12, 8, 12}, font_size = 14},
  ["input#focus"]  = {border = {136, 192, 208}},
  button           = {bg = {76, 86, 106}, color = {236, 239, 244},
                      radius = 6, padding = {6, 14, 6, 14}, font_size = 13},
  ["button#hover"] = {bg = {94, 105, 126}},
})

dataflow.init({
  items = {},
  input_value = "",
})

-- Handlers

reg_handler("todo/input", function(db, event)
  local ctx = event[2]
  assoc(db, "input_value", ctx.value or "")
  return db
end)

reg_handler("todo/add", function(db, event)
  local val = get(db, "input_value", "")
  if val == "" then return db end
  update(db, "items", function(items)
    table.insert(items, {text = val})
    return items
  end)
  assoc(db, "input_value", "")
  return db
end)

-- Subscriptions

reg_sub("items", function(db)
  return get(db, "items", {})
end)

reg_sub("input_value", function(db)
  return get(db, "input_value", "")
end)

-- View

function main_view()
  local items = subscribe("items")
  local input_val = subscribe("input_value")

  local rows = {}
  for _, item in ipairs(items or {}) do
    table.insert(rows, {"text", {aspect = "body"}, item.text})
  end

  return {
    frame = {"vbox", {},
      {"stack", {},
        {"vbox", {aspect = "surface", layout = "center"},
          {"text", {aspect = "heading", layout = "center"}, "Todo List"},
          {"input", {aspect = "input", width = 250, height = 42,
                     value = input_val,
                     change = {"todo/input"}, key = {"todo/add"}}},
          {"button", {width = 250, height = 42, aspect = "button",
                      click = {"todo/add"}}, "Add"},
          {"vbox", {overflow = "scroll-y", aspect = "muted"},
            table.unpack(rows)}}}},
    bind = {}
  }
end
```

---

## Running

Build the host binary once:

```sh
odin build src/host -out:build/redin
```

Then run your Lua app:

```sh
./build/redin todo.lua
```

Dev mode starts the HTTP dev server on `localhost:8800`:

```sh
./build/redin --dev todo.lua
```

```sh
# Inspect live state
curl localhost:8800/state

# Dispatch an event from the terminal
curl -X POST localhost:8800/events \
  -H 'Content-Type: application/json' \
  -d '{"event": ["todo/add"]}'
```

See [core-api.md](../core-api.md) and [app-api.md](../app-api.md) for the full API
reference.
