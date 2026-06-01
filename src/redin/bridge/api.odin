// Public API: published bridge primitives for user-owned `app.odin` code
// to extend redin without forking framework files. RFC #79 PR 2.
package bridge

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:sync"

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

	when REDIN_DEV {
		if field_is_set(L, name) {
			fmt.eprintfln("redin: warn: bridge.register_cfunc(%q) replaces an existing binding", name)
		}
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

	when REDIN_DEV {
		if field_is_set(L, name) {
			fmt.eprintfln("redin: warn: bridge.register_cfunc_raw(%q) replaces an existing binding", name)
		}
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

// ---------------------------------------------------------------------------
// Outbound HTTP destination whitelist (issue #99 M4; SSRF hardening #162 M3)
// ---------------------------------------------------------------------------
//
// The whitelist is deny-by-default (#136 H2): with nothing set, redin.http
// refuses every host. An app opts in via `bridge.set_http_whitelist` with a
// mix of:
//
//   - an access-class keyword controlling which IP *ranges* are reachable:
//       "all"      — any address (the historical open behaviour; "*" is an alias)
//       "local"    — loopback only (127/8, ::1)
//       "external" — public addresses only; loopback, link-local, RFC1918,
//                    ULA, and cloud-metadata ranges are blocked
//   - explicit hostname literals (case-insensitive) and CIDRs, which are
//     always allowed regardless of the class (e.g. ["external","127.0.0.1"]
//     reaches public hosts plus that one loopback service).
//
// #162 M3: the class is enforced against the *resolved* IP, so a public
// hostname that resolves into a blocked range is caught (DNS-rebinding
// defence). See execute_http_request.
//
// #129 L2: hostname comparison is ASCII-byte case-insensitive. IDN
// hostnames must be passed in their punycode (xn--...) form;
// `münchen.example` is not equivalent to `xn--mnchen-3ya.example`
// for whitelist matching.

// Access_Class is the IP-range policy parsed from a class keyword.
Access_Class :: enum {
	None,     // no class keyword present — deny unless an explicit entry matches
	All,      // any address
	Local,    // loopback only
	External, // public addresses only
}

// parse_access_class maps a whitelist entry to its class, or .None if the
// entry is not a class keyword (i.e. it's a hostname/CIDR literal). "*" is
// the back-compat alias for "all".
parse_access_class :: proc(entry: string) -> Access_Class {
	switch entry {
	case "all", "*": return .All
	case "local":    return .Local
	case "external": return .External
	}
	return .None
}

// --- IP-range classification ---

ip4_is_loopback :: proc(a: net.IP4_Address) -> bool {
	return a[0] == 127 // 127.0.0.0/8
}

// Private-or-local covers everything the "external" class must block:
// loopback, RFC1918, link-local (incl. cloud metadata 169.254.169.254),
// and CGNAT 100.64/10.
ip4_is_private_or_local :: proc(a: net.IP4_Address) -> bool {
	switch {
	case a[0] == 127:                              return true // loopback
	case a[0] == 10:                               return true // 10/8
	case a[0] == 172 && a[1] >= 16 && a[1] <= 31:  return true // 172.16/12
	case a[0] == 192 && a[1] == 168:               return true // 192.168/16
	case a[0] == 169 && a[1] == 254:               return true // link-local + metadata
	case a[0] == 100 && a[1] >= 64 && a[1] <= 127: return true // CGNAT 100.64/10
	case a[0] == 0:                                 return true // 0.0.0.0/8 "this host"
	}
	return false
}

ip6_is_loopback :: proc(a: net.IP6_Address) -> bool {
	return a == net.IP6_Loopback
}

ip6_is_private_or_local :: proc(a: net.IP6_Address) -> bool {
	if a == net.IP6_Loopback do return true
	b := transmute([16]u8)a
	switch {
	case b[0] == 0xfe && (b[1] & 0xc0) == 0x80: return true // fe80::/10 link-local
	case (b[0] & 0xfe) == 0xfc:                 return true // fc00::/7 ULA
	}
	return false
}

// access_decide_ip4 / _ip6: does `class` permit dialing this resolved IP,
// ignoring explicit entries (those are checked separately and always win).
access_decide_ip4 :: proc(class: Access_Class, a: net.IP4_Address) -> bool {
	switch class {
	case .All:      return true
	case .Local:    return ip4_is_loopback(a)
	case .External: return !ip4_is_private_or_local(a)
	case .None:     return false
	}
	return false
}

access_decide_ip6 :: proc(class: Access_Class, a: net.IP6_Address) -> bool {
	switch class {
	case .All:      return true
	case .Local:    return ip6_is_loopback(a)
	case .External: return !ip6_is_private_or_local(a)
	case .None:     return false
	}
	return false
}

@(private)
g_http_whitelist:       []string
@(private)
g_http_access_class:    Access_Class
@(private)
g_http_whitelist_mutex: sync.Mutex

set_http_whitelist :: proc(allow: []string) {
	sync.lock(&g_http_whitelist_mutex)
	defer sync.unlock(&g_http_whitelist_mutex)

	// Use the process-wide heap allocator so storage is independent of the
	// caller's per-thread allocator (e.g. Odin's per-test tracking allocator).
	// In production this matters because the dev-server thread that runs
	// http_whitelist_check is not the thread that called set_http_whitelist.
	heap := runtime.heap_allocator()

	for s in g_http_whitelist do delete(s, heap)
	delete(g_http_whitelist, heap)
	g_http_whitelist = nil
	g_http_access_class = .None

	if allow == nil do return

	cloned := make([]string, len(allow), heap)
	for s, i in allow do cloned[i] = strings.clone(s, heap)
	g_http_whitelist = cloned

	// Derive the access class from any class keyword(s) present. If more
	// than one is given the most permissive wins (All > External > Local),
	// so a broadening keyword is never silently dropped.
	for entry in allow {
		switch parse_access_class(entry) {
		case .All:      g_http_access_class = .All
		case .External: if g_http_access_class != .All do g_http_access_class = .External
		case .Local:    if g_http_access_class == .None do g_http_access_class = .Local
		case .None:     // hostname / CIDR literal — not a class
		}
	}
}

// http_whitelist_check reports whether an *explicit* entry (hostname
// literal, case-insensitive, or CIDR) matches `host`, or the class is All.
// It is the string-level check used directly by unit tests; the live
// request path uses http_access_allowed, which additionally enforces the
// access class against the resolved IP. Returns ("", true) when allowed,
// ("<host>", false) otherwise.
@(private)
http_whitelist_check :: proc(host: string) -> (rejected: string, ok: bool) {
	sync.lock(&g_http_whitelist_mutex)
	defer sync.unlock(&g_http_whitelist_mutex)

	if g_http_access_class == .All do return "", true

	host_lower := strings.to_lower(host, context.temp_allocator)
	for entry in g_http_whitelist {
		if parse_access_class(entry) != .None do continue // skip class keywords
		if strings.contains(entry, "/") {
			if cidr_match(host, entry) do return "", true
			continue
		}
		entry_lower := strings.to_lower(entry, context.temp_allocator)
		if host_lower == entry_lower do return "", true
	}
	return host, false
}

// http_access_allowed is the live SSRF gate. `host` is the URL host as
// written (hostname or IP literal); `addr` is the IP it resolved to and
// that we are about to dial. An explicit hostname/CIDR entry allows
// unconditionally (the explicit opt-in always wins); otherwise the access
// class is enforced against the resolved IP — so a public hostname that
// resolves into a blocked range is rejected (#162 M3, DNS-rebinding).
@(private)
http_access_allowed :: proc(host: string, addr: net.Address) -> bool {
	sync.lock(&g_http_whitelist_mutex)
	defer sync.unlock(&g_http_whitelist_mutex)

	host_lower := strings.to_lower(host, context.temp_allocator)
	ip_str := net.address_to_string(addr, context.temp_allocator)
	for entry in g_http_whitelist {
		if parse_access_class(entry) != .None do continue // skip class keywords
		if strings.contains(entry, "/") {
			// CIDRs match against the resolved IP, not the host string —
			// so an explicit CIDR carve-out works for hostnames too.
			if cidr_match(ip_str, entry) do return true
			continue
		}
		entry_lower := strings.to_lower(entry, context.temp_allocator)
		if host_lower == entry_lower do return true
	}

	switch a in addr {
	case net.IP4_Address: return access_decide_ip4(g_http_access_class, a)
	case net.IP6_Address: return access_decide_ip6(g_http_access_class, a)
	}
	return false
}

@(private = "file")
cidr_match :: proc(host: string, cidr: string) -> bool {
	slash := strings.last_index_byte(cidr, '/')
	if slash < 0 do return false
	prefix := cidr[:slash]
	bits_str := cidr[slash+1:]

	// IPv4 path: prefix parses as v4.
	if v4, ok := net.parse_ip4_address(prefix); ok {
		host_v4, ok2 := net.parse_ip4_address(host)
		if !ok2 do return false
		bits, parse_ok := strconv.parse_int(bits_str, 10)
		if !parse_ok || bits < 0 || bits > 32 do return false
		return cidr4_match_bits(host_v4, v4, bits)
	}

	// IPv6 path.
	v6, ok := net.parse_ip6_address(prefix)
	if !ok do return false
	host_v6, ok2 := net.parse_ip6_address(host)
	if !ok2 do return false
	bits, parse_ok := strconv.parse_int(bits_str, 10)
	if !parse_ok || bits < 0 || bits > 128 do return false
	return cidr6_match_bits(host_v6, v6, bits)
}

@(private = "file")
cidr4_match_bits :: proc(host: net.IP4_Address, net_addr: net.IP4_Address, bits: int) -> bool {
	if bits == 0 do return true
	host_u := u32(host[0])<<24 | u32(host[1])<<16 | u32(host[2])<<8 | u32(host[3])
	net_u  := u32(net_addr[0])<<24 | u32(net_addr[1])<<16 | u32(net_addr[2])<<8 | u32(net_addr[3])
	mask: u32 = bits == 32 ? 0xFFFFFFFF : (0xFFFFFFFF << u32(32 - bits))
	return (host_u & mask) == (net_u & mask)
}

@(private = "file")
cidr6_match_bits :: proc(host: net.IP6_Address, net_addr: net.IP6_Address, bits: int) -> bool {
	if bits == 0 do return true
	// IP6_Address is `distinct [8]u16be`, i.e. 16 bytes laid out in network
	// byte order. Transmute to a flat [16]u8 for a clean byte-by-byte
	// CIDR comparison.
	host_bytes := transmute([16]u8)host
	net_bytes  := transmute([16]u8)net_addr
	full_bytes := bits / 8
	rem_bits   := bits % 8
	for i in 0 ..< full_bytes {
		if host_bytes[i] != net_bytes[i] do return false
	}
	if rem_bits > 0 {
		mask: u8 = u8(0xFF) << u8(8 - rem_bits)
		if (host_bytes[full_bytes] & mask) != (net_bytes[full_bytes] & mask) do return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Shell env allowlist (issue #99 M3)
// ---------------------------------------------------------------------------
//
// When unset (default), child processes spawned by redin.shell inherit the
// full parent env (Process_Desc.env = nil is the documented "inherit"
// sentinel; see core/os/process.odin). When set, only keys present in the
// allowlist are passed through to the child. Exact match, case-sensitive.
//
// #129 L3: case-sensitive is intentional — Linux env keys are
// case-sensitive (`PATH` ≠ `path`), so the allowlist matches the
// underlying semantics. This is asymmetric to the HTTP host
// whitelist (case-insensitive), which mirrors DNS rules.
//
// Storage uses runtime.heap_allocator() for the same reason as the HTTP
// whitelist: the allowlist is read on the shell worker thread and written
// from the main thread; under Odin's parallel test runner, per-thread
// tracking allocators would otherwise produce spurious "bad free"
// warnings.

@(private)
g_shell_env_allowlist:       []string
@(private)
g_shell_env_allowlist_mutex: sync.Mutex

set_shell_env_allowlist :: proc(allow: []string) {
	sync.lock(&g_shell_env_allowlist_mutex)
	defer sync.unlock(&g_shell_env_allowlist_mutex)

	heap := runtime.heap_allocator()

	for s in g_shell_env_allowlist do delete(s, heap)
	delete(g_shell_env_allowlist, heap)
	g_shell_env_allowlist = nil

	if allow == nil do return

	cloned := make([]string, len(allow), heap)
	for s, i in allow do cloned[i] = strings.clone(s, heap)
	g_shell_env_allowlist = cloned
}

// Shell_Env_Disposition tells the caller what to put in Process_Desc.env.
// Returned by shell_env_filtered.
Shell_Env_Disposition :: enum {
	// Pass Process_Desc.env = nil — child inherits the full parent env.
	// Only reached when the allowlist contains the sentinel "*" entry.
	Inherit,
	// Pass Process_Desc.env = <non-nil zero-length slice> — child gets
	// an empty environment. Reached when the allowlist is nil or empty
	// (the deny-by-default case from #136 H3).
	Empty,
	// Pass Process_Desc.env = filtered (returned slice). Child sees only
	// the env vars whose KEYs match an allowlist entry.
	Filtered,
}

// shell_env_filtered returns:
//   - Inherit, nil          → caller sets env = nil (full passthrough)
//   - Empty, nil            → caller substitutes a non-nil zero-length
//                              slice (e.g. a stack-backed slice) so
//                              Process_Desc.env != nil and the child
//                              gets an empty environment
//   - Filtered, owned-slice → caller assigns env directly. The slice's
//                              entries + the slice itself are owned by
//                              the caller and must be freed with the
//                              heap allocator after process_start.
//
// Defaults (#136 H3): an unset or empty allowlist gives the child an
// empty environment. To re-enable the historical full-passthrough
// behaviour, call `bridge.set_shell_env_allowlist([]string{"*"})` from
// app.odin — the `"*"` entry is a sentinel wildcard.
@(private)
shell_env_filtered :: proc() -> (env: []string, disposition: Shell_Env_Disposition) {
	sync.lock(&g_shell_env_allowlist_mutex)
	defer sync.unlock(&g_shell_env_allowlist_mutex)

	heap := runtime.heap_allocator()

	// Sentinel wildcard — explicit opt-out of the deny-by-default policy.
	for entry in g_shell_env_allowlist {
		if entry == "*" do return nil, .Inherit
	}

	// Unset or empty allowlist → empty env.
	if len(g_shell_env_allowlist) == 0 do return nil, .Empty

	// os.environ allocates a fresh []string + cloned KEY=VALUE entries
	// using the supplied allocator. Free the unused entries below.
	all_env, env_err := os.environ(heap)
	if env_err != nil {
		// Fall back to an explicit "no env" rather than passthrough; if the
		// caller set an allowlist they explicitly opted into restriction,
		// so a fetch failure must not silently widen the surface.
		return nil, .Empty
	}
	defer delete(all_env, heap)

	out := make([dynamic]string, 0, len(g_shell_env_allowlist), heap)
	for entry in all_env {
		// `entry` is "KEY=VALUE"; extract KEY.
		eq := strings.index_byte(entry, '=')
		if eq < 0 {
			delete(entry, heap)
			continue
		}
		key := entry[:eq]
		matched := false
		for allow in g_shell_env_allowlist {
			if key == allow {
				matched = true
				break
			}
		}
		if matched {
			append(&out, entry) // transfer ownership of the cloned string
		} else {
			delete(entry, heap)
		}
	}
	return out[:], .Filtered
}
