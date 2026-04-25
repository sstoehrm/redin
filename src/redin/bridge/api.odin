// Public API: published bridge primitives for user-owned `app.odin` code
// to extend redin without forking framework files. RFC #79 PR 2.
package bridge

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"

// ---------------------------------------------------------------------------
// Context propagation
// ---------------------------------------------------------------------------

// Returns the runtime context the bridge captured during init. User cfuncs
// registered via register_cfunc_raw (the proc "c" escape hatch) need to set
// `context = bridge.host_context()` at entry to restore the tracking
// allocator and other context-bound state. register_cfunc handles this
// automatically via the trampoline.
host_context :: proc "contextless" () -> runtime.Context {
	return g_context
}

// ---------------------------------------------------------------------------
// Lua cfunc registration (works before or after bridge.init)
// ---------------------------------------------------------------------------
//
// User code typically calls register_cfunc before redin.run (which is
// when bridge.init runs). Registrations made before init are buffered
// and flushed by flush_pending_cfuncs() at the end of init, after the
// `redin` Lua global has been created.
//
// Post-init, registrations apply immediately by looking up the redin
// table via lua_getglobal.

@(private = "file")
Pending_Cfunc :: struct {
	name:   cstring,
	fn:     proc(L: ^Lua_State) -> i32, // used when is_raw == false
	raw:    Lua_CFunction,                // used when is_raw == true
	is_raw: bool,
}

@(private = "file")
g_pending_cfuncs: [dynamic]Pending_Cfunc

// Internal: called from bridge.init after the redin Lua global exists,
// to apply any registrations that were buffered before init.
flush_pending_cfuncs :: proc() {
	if len(g_pending_cfuncs) == 0 do return
	for p in g_pending_cfuncs {
		if p.is_raw {
			apply_register_cfunc_raw(p.name, p.raw)
		} else {
			apply_register_cfunc(p.name, p.fn)
		}
	}
	delete(g_pending_cfuncs)
	g_pending_cfuncs = nil
}

// Register a Lua cfunc using a regular Odin proc (default calling
// convention). The bridge wraps it in a static `proc "c"` trampoline that
// sets context = host_context() and dispatches via a Lua upvalue holding
// the user proc pointer — so user code never types `proc "c"` and never
// calls host_context() directly.
//
// Safe to call before bridge.init (registrations are buffered) or after
// (applied immediately).
//
// Duplicate name: silent replace. In dev mode, logs a stderr warning before
// replacing (matches canvas.register's policy).
register_cfunc :: proc(name: cstring, fn: proc(L: ^Lua_State) -> i32) {
	if g_bridge == nil {
		append(&g_pending_cfuncs, Pending_Cfunc{name = name, fn = fn})
		return
	}
	apply_register_cfunc(name, fn)
}

// Register a raw `proc "c"` cfunc directly. Caller is responsible for
// `context = bridge.host_context()` inside the proc body. Use this only
// when you genuinely need the raw C calling convention (e.g. integration
// with another C library that already provides a proc "c"); otherwise
// prefer register_cfunc.
//
// Safe to call before or after bridge.init.
register_cfunc_raw :: proc(name: cstring, fn: Lua_CFunction) {
	if g_bridge == nil {
		append(&g_pending_cfuncs, Pending_Cfunc{name = name, raw = fn, is_raw = true})
		return
	}
	apply_register_cfunc_raw(name, fn)
}

@(private = "file")
apply_register_cfunc :: proc(name: cstring, fn: proc(L: ^Lua_State) -> i32) {
	L := g_bridge.L
	if !get_redin_table(L, "register_cfunc", name) do return

	if g_bridge.dev_mode && field_is_set(L, name) {
		fmt.eprintfln("redin: warn: bridge.register_cfunc(%q) replaces an existing binding", name)
	}

	// Push the user proc pointer as a lightuserdata upvalue, then build a
	// closure of `cfunc_trampoline` that captures it. The trampoline pulls
	// the pointer back out at call time via lua_upvalueindex(1).
	lua_pushlightuserdata(L, rawptr(fn))
	lua_pushcclosure(L, cfunc_trampoline, 1)
	lua_setfield(L, -2, name)

	lua_pop(L, 1) // pop redin table
}

@(private = "file")
apply_register_cfunc_raw :: proc(name: cstring, fn: Lua_CFunction) {
	L := g_bridge.L
	if !get_redin_table(L, "register_cfunc_raw", name) do return

	if g_bridge.dev_mode && field_is_set(L, name) {
		fmt.eprintfln("redin: warn: bridge.register_cfunc_raw(%q) replaces an existing binding", name)
	}

	lua_pushcfunction(L, fn)
	lua_setfield(L, -2, name)
	lua_pop(L, 1)
}

@(private = "file")
get_redin_table :: proc(L: ^Lua_State, caller: string, name: cstring) -> bool {
	lua_getglobal(L, "redin")
	if !lua_istable(L, -1) {
		lua_pop(L, 1)
		fmt.eprintfln(
			"redin: error: bridge.%s(%s) called before bridge.init created the redin global",
			caller, name,
		)
		return false
	}
	return true
}

@(private = "file")
field_is_set :: proc(L: ^Lua_State, name: cstring) -> bool {
	lua_getfield(L, -1, name)
	exists := !lua_isnil(L, -1)
	lua_pop(L, 1)
	return exists
}

// Static trampoline shared by all register_cfunc registrations. The user
// proc pointer is recovered from upvalue 1, context is set, then the user
// proc runs with full Odin defaults (auto-propagated context, allocator).
@(private = "file")
cfunc_trampoline :: proc "c" (L: ^Lua_State) -> i32 {
	context = g_context

	user_fn_ptr := lua_touserdata(L, lua_upvalueindex(1))
	if user_fn_ptr == nil {
		fmt.eprintln("redin: error: cfunc trampoline upvalue is nil — corrupt registration?")
		return 0
	}
	user_fn := cast(proc(L: ^Lua_State) -> i32)user_fn_ptr
	return user_fn(L)
}

// ---------------------------------------------------------------------------
// Odin → Lua marshaller
// ---------------------------------------------------------------------------

@(private = "file")
MAX_PUSH_DEPTH :: 32

// Push one Odin value onto the Lua stack. Supported types:
//   nil                                   → Lua nil
//   bool                                  → Lua boolean
//   integer (i8..i64, u8..u64), enum     → Lua number
//   f32, f64                              → Lua number
//   string, cstring                       → Lua string
//   []T, [N]T                             → Lua array table (1-indexed)
//   map[string]T (or any string-keyed)    → Lua keyed table
//   struct                                → Lua keyed table (field name → value)
//   union                                 → active variant pushed; nil if unset
//   ^T                                    → deref and recurse; nil if pointer is nil
//   any                                   → recurse on the wrapped value
// Unsupported types push nil and log a warning.
// Bails at recursion depth MAX_PUSH_DEPTH (cycle guard); pushes nil + warns.
push :: proc(L: ^Lua_State, value: any) {
	push_at_depth(L, value, 0)
}

@(private = "file")
push_at_depth :: proc(L: ^Lua_State, value: any, depth: int) {
	if depth >= MAX_PUSH_DEPTH {
		fmt.eprintfln("redin: warn: bridge.push bailed at depth %d (circular reference?)", depth)
		lua_pushnil(L)
		return
	}

	if value.data == nil || value.id == nil {
		lua_pushnil(L)
		return
	}

	ti := runtime.type_info_base(type_info_of(value.id))

	#partial switch v in ti.variant {
	case runtime.Type_Info_Boolean:
		b, ok := reflect.as_bool(value)
		if ok {
			lua_pushboolean(L, b ? 1 : 0)
		} else {
			lua_pushnil(L)
		}

	case runtime.Type_Info_Integer:
		// Keep precision: use i64 path for signed, u64 for unsigned.
		if v.signed {
			n, ok := reflect.as_i64(value)
			if ok { lua_pushinteger(L, n) } else { lua_pushnil(L) }
		} else {
			n, ok := reflect.as_u64(value)
			if ok { lua_pushinteger(L, i64(n)) } else { lua_pushnil(L) }
		}

	case runtime.Type_Info_Float:
		n, ok := reflect.as_f64(value)
		if ok { lua_pushnumber(L, n) } else { lua_pushnil(L) }

	case runtime.Type_Info_Enum:
		// Push as integer using the underlying base type.
		base_value := any{data = value.data, id = v.base.id}
		push_at_depth(L, base_value, depth + 1)

	case runtime.Type_Info_String:
		s, ok := reflect.as_string(value)
		if ok {
			cs := strings.clone_to_cstring(s, context.temp_allocator)
			lua_pushstring(L, cs)
		} else {
			lua_pushnil(L)
		}

	case runtime.Type_Info_Pointer:
		ptr := (^rawptr)(value.data)^
		if ptr == nil {
			lua_pushnil(L)
		} else {
			elem := any{data = ptr, id = v.elem.id}
			push_at_depth(L, elem, depth + 1)
		}

	case runtime.Type_Info_Slice:
		slice := (^runtime.Raw_Slice)(value.data)^
		push_array(L, slice.data, slice.len, v.elem, v.elem_size, depth)

	case runtime.Type_Info_Array:
		push_array(L, value.data, v.count, v.elem, v.elem_size, depth)

	case runtime.Type_Info_Dynamic_Array:
		da := (^runtime.Raw_Dynamic_Array)(value.data)^
		push_array(L, da.data, da.len, v.elem, v.elem_size, depth)

	case runtime.Type_Info_Map:
		push_map(L, value, v, depth)

	case runtime.Type_Info_Struct:
		push_struct(L, value, v, depth)

	case runtime.Type_Info_Union:
		push_union(L, value, v, depth)

	case runtime.Type_Info_Any:
		// `any` wraps another any. Recurse on the wrapped value.
		inner := (^any)(value.data)^
		push_at_depth(L, inner, depth + 1)

	case:
		fmt.eprintfln("redin: warn: bridge.push: unsupported type %v", value.id)
		lua_pushnil(L)
	}
}

@(private = "file")
push_array :: proc(L: ^Lua_State, data: rawptr, count: int, elem: ^runtime.Type_Info, elem_size: int, depth: int) {
	lua_createtable(L, i32(count), 0)
	for i in 0 ..< count {
		item_data := rawptr(uintptr(data) + uintptr(i * elem_size))
		item := any{data = item_data, id = elem.id}
		push_at_depth(L, item, depth + 1)
		lua_rawseti(L, -2, i32(i + 1)) // Lua arrays are 1-indexed
	}
}

@(private = "file")
push_struct :: proc(L: ^Lua_State, value: any, info: runtime.Type_Info_Struct, depth: int) {
	lua_createtable(L, 0, info.field_count)
	for i in 0 ..< int(info.field_count) {
		field_data := rawptr(uintptr(value.data) + info.offsets[i])
		field_value := any{data = field_data, id = info.types[i].id}
		push_at_depth(L, field_value, depth + 1)
		// Stack: [..., table, field_value]
		name := strings.clone_to_cstring(info.names[i], context.temp_allocator)
		lua_setfield(L, -2, name)
	}
}

@(private = "file")
push_union :: proc(L: ^Lua_State, value: any, info: runtime.Type_Info_Union, depth: int) {
	tag_ptr := rawptr(uintptr(value.data) + info.tag_offset)
	tag: i64
	switch info.tag_type.size {
	case 1: tag = i64((^i8)(tag_ptr)^)
	case 2: tag = i64((^i16)(tag_ptr)^)
	case 4: tag = i64((^i32)(tag_ptr)^)
	case 8: tag = (^i64)(tag_ptr)^
	case:   tag = 0
	}
	if tag == 0 {
		lua_pushnil(L)
		return
	}
	variant := info.variants[tag - 1]
	inner := any{data = value.data, id = variant.id}
	push_at_depth(L, inner, depth + 1)
}

@(private = "file")
push_map :: proc(L: ^Lua_State, value: any, info: runtime.Type_Info_Map, depth: int) {
	lua_createtable(L, 0, 0)

	it: int
	for k, val in reflect.iterate_map(value, &it) {
		// Push key. We accept any type that the marshaller would push as a
		// Lua scalar — string is the common case (map[string]T) and works
		// the cleanest. Numbers, bools, etc. also work via push_at_depth.
		push_at_depth(L, k, depth + 1)
		push_at_depth(L, val, depth + 1)
		lua_settable(L, -3)
	}
}

// ---------------------------------------------------------------------------
// Native → Fennel dispatch
// ---------------------------------------------------------------------------
//
// `redin_events` is a Fennel-side function (view.deliver-events) registered
// as a Lua global at runtime startup. It expects an array of entries where
// each entry has the shape ["dispatch", [event_name, payload?]].

// Zero-copy variant: the caller has already pushed the payload onto the
// top of the Lua stack. Wraps it in ["dispatch", [event, payload]],
// appends to a one-element events array, and calls redin_events. The
// payload is consumed regardless of success.
//
// Use this in hot paths (per-frame state push) where the caller can
// avoid the reflection cost by building the payload directly with
// lua_push* helpers. See `dispatch` for the high-level variant.
dispatch_tos :: proc(L: ^Lua_State, event: string) -> (ok: bool, err: string) {
	// Stack on entry: [..., payload]
	lua_getglobal(L, "redin_events")
	if lua_isnil(L, -1) {
		lua_pop(L, 2) // pop nil redin_events + payload
		return false, "redin_events is not registered (Fennel runtime not loaded)"
	}
	// Stack: [..., payload, redin_events]
	// payload is at -2; we need it copied into the events array below.

	// events[1] = ["dispatch", [event, payload]]
	lua_createtable(L, 1, 0) // events
	lua_createtable(L, 2, 0) // wrapper
	lua_pushstring(L, "dispatch")
	lua_rawseti(L, -2, 1) // wrapper[1] = "dispatch"

	lua_createtable(L, 2, 0) // inner
	ev_cs := strings.clone_to_cstring(event, context.temp_allocator)
	lua_pushstring(L, ev_cs)
	lua_rawseti(L, -2, 1) // inner[1] = event_name

	// Stack now: [..., payload, redin_events, events, wrapper, inner]
	// Original payload sits at index -5. Copy it as inner[2].
	lua_pushvalue(L, -5)
	lua_rawseti(L, -2, 2) // inner[2] = payload (pops the copy)

	lua_rawseti(L, -2, 2) // wrapper[2] = inner
	lua_rawseti(L, -2, 1) // events[1] = wrapper

	// Stack: [..., payload, redin_events, events]
	// pcall consumes redin_events + events; payload is left dangling and
	// we pop it ourselves at the end (regardless of success/failure).
	if lua_pcall(L, 1, 0, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		err_owned := strings.clone_from_cstring(msg, context.temp_allocator)
		lua_pop(L, 2) // error msg + original payload
		return false, err_owned
	}

	lua_pop(L, 1) // original payload
	return true, ""
}

// Dispatch an event with an Odin-side payload. Marshals the payload via
// `push` (reflection-based), wraps in ["dispatch", [event, payload]],
// and appends to redin_events. Suitable for non-hot-path callers; for
// per-frame pushes prefer building the payload directly and using
// dispatch_tos.
dispatch :: proc(event: string, payload: any) -> (ok: bool, err: string) {
	if g_bridge == nil {
		return false, "bridge.dispatch called before bridge.init"
	}
	push(g_bridge.L, payload)
	return dispatch_tos(g_bridge.L, event)
}
