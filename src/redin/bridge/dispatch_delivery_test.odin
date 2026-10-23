package bridge

import "core:sync"
import "core:testing"
import "../types"

// Review C1: deliver_dispatch_events' Key_Event_Dispatch branch was one
// lua_rawseti short — the ctx table landed in inner[2], then *inner*
// overwrote wrapper[1] ("dispatch"), the wrapper was never stored, and the
// pcall called the events table itself ("attempt to call a table value"),
// leaving redin_events on the stack (+1 slot per keypress). Every `:key`
// handler on an `:input` was dead.
//
// These tests deliver each Dispatch_Event variant into a capturing
// `redin_events` and assert (a) the [[:dispatch [name ctx]]] shape and
// (b) that the Lua stack is balanced afterwards.

@(private = "file")
setup_capture :: proc(t: ^testing.T, L: ^Lua_State) {
	code: cstring = `captured = {}
function redin_events(evs) captured[#captured + 1] = evs end`
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "failed to install capturing redin_events (rc=%d)", rc)
}

// Evaluate a Lua expression returning a string; "" on error/non-string.
@(private = "file")
eval_string :: proc(L: ^Lua_State, code: cstring) -> string {
	top := lua_gettop(L)
	defer lua_settop(L, top)
	if luaL_dostring(L, code) != 0 do return ""
	if !lua_isstring(L, -1) do return ""
	return lua_clone_string(L, -1, context.temp_allocator)
}

@(test)
test_deliver_key_event_dispatch_shape_and_stack :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	b: Bridge
	b.L = L
	setup_capture(t, L)

	top_before := lua_gettop(L)
	imbalances_before := g_dispatch_stack_imbalances
	events := []types.Dispatch_Event{
		types.Key_Event_Dispatch{
			event_name = "ev/key",
			key        = "enter",
			mods       = {shift = true},
		},
	}
	deliver_dispatch_events(&b, events)

	testing.expectf(t, lua_gettop(L) == top_before,
		"Lua stack unbalanced after key dispatch: before=%d after=%d",
		top_before, lua_gettop(L))
	testing.expectf(t, g_dispatch_stack_imbalances == imbalances_before,
		"key dispatch branch left the Lua stack unbalanced (guard fired %d time(s))",
		g_dispatch_stack_imbalances - imbalances_before)

	got := eval_string(L, `local e = captured[1]
if type(e) ~= "table" then return "no-capture" end
local w = e[1]
if type(w) ~= "table" then return "no-wrapper" end
local inner = w[2]
if type(inner) ~= "table" then return "wrapper=" .. tostring(w[1]) .. " no-inner" end
local ctx = inner[2]
if type(ctx) ~= "table" then return "no-ctx" end
return table.concat({tostring(w[1]), tostring(inner[1]), tostring(ctx.key),
  tostring(ctx.mods and ctx.mods.shift), tostring(ctx.mods and ctx.mods.ctrl)}, "|")`)
	testing.expect_value(t, got, "dispatch|ev/key|enter|true|false")
}

@(test)
test_deliver_all_dispatch_variants_keep_stack_balanced :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	b: Bridge
	b.L = L
	setup_capture(t, L)

	events := []types.Dispatch_Event{
		types.Change_Event{event_name = "ev/change", value = "abc"},
		types.Click_Event{event_name = "ev/click"},
		types.Key_Event_Dispatch{event_name = "ev/key", key = "escape"},
		types.Drag_Event{event_name = "ev/drag"},
		types.Drop_Event{event_name = "ev/drop"},
		types.Drag_Over_Event{event_name = "ev/over", phase = .Enter},
	}
	top_before := lua_gettop(L)
	imbalances_before := g_dispatch_stack_imbalances
	deliver_dispatch_events(&b, events)
	testing.expectf(t, lua_gettop(L) == top_before,
		"Lua stack unbalanced after dispatch delivery: before=%d after=%d",
		top_before, lua_gettop(L))
	testing.expectf(t, g_dispatch_stack_imbalances == imbalances_before,
		"a dispatch branch left the Lua stack unbalanced (guard fired %d time(s))",
		g_dispatch_stack_imbalances - imbalances_before)

	// Every variant must arrive as {{"dispatch", {name, ...}}}.
	got := eval_string(L, `local out = {}
for i = 1, #captured do
  local w = captured[i][1]
  if type(w) == "table" and type(w[2]) == "table" then
    out[#out + 1] = tostring(w[1]) .. ":" .. tostring(w[2][1])
  else
    out[#out + 1] = "bad"
  end
end
return table.concat(out, ",")`)
	testing.expect_value(t, got,
		"dispatch:ev/change,dispatch:ev/click,dispatch:ev/key,dispatch:ev/drag,dispatch:ev/drop,dispatch:ev/over")
}
