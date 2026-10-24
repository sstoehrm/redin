package bridge

import "core:strings"
import "../types"

// Composed aspects — `{:aspect [:a :b]}` (docs/core-api.md § Aspect
// composition, docs/reference/theme.md § Composition + state merge order).
//
// Design: every theme consumer (render, input, text selection) looks up a
// single aspect string in the theme map (`theme[n.aspect]`, plus
// `theme[n.aspect + "#hover"]` etc. for state variants). Rather than teach
// each of those sites about lists, flatten turns an aspect list into one
// synthetic key ("a b") and the bridge keeps a theme entry for it:
//
//   theme["a b"]        = a < b                    (later wins, per field)
//   theme["a b#hover"]  = a#hover < b#hover        (only if either exists)
//   ... same for #focus / #active / #disabled
//
// The renderer then applies base < #focus < #hover < #active as for any
// plain aspect, which yields exactly the documented order for one state:
// a, b, a#hover, b#hover (overlay is per-field last-non-zero-wins, so
// overlaying a precomposed "a#hover < b#hover" equals overlaying them one
// by one).
//
// The separator is a space: it cannot occur in a Fennel keyword, so a
// synthetic key never collides with an aspect an app can name with
// `:keyword` syntax. Parts that are empty or contain a space are dropped.
//
// Lifetimes: synthetic entries live in `Bridge.theme` and follow its
// ownership rules (heap key + heap `font`, freed by free_theme_map). The
// set of composed keys seen so far lives in `Bridge.composed_aspects`
// (owned keys, freed in destroy) so redin_set_theme can rebuild the
// synthetic entries after every theme swap (including PUT /aspects)
// without waiting for a re-flatten. The registry only grows by distinct
// compositions the app actually uses.

COMPOSED_ASPECT_SEP :: " "

// "" = the base entry. Must cover every `#state` suffix a theme consumer
// looks up (render.resolve_themed_aspect: #focus/#hover/#active).
COMPOSED_ASPECT_SUFFIXES :: [?]string{"", "#focus", "#hover", "#active", "#disabled"}

// Merge `part + suffix` for each part, left to right (later wins per
// field). found=false when no part has an entry — callers then leave the
// composed key absent, matching the lookup-miss of a missing plain aspect.
// The returned `font` aliases the source entry; clone before storing.
compose_theme_entry :: proc(
	theme: map[string]types.Theme,
	parts: []string,
	suffix: string,
) -> (result: types.Theme, found: bool) {
	for part in parts {
		key := strings.concatenate({part, suffix}, context.temp_allocator)
		if t, ok := theme[key]; ok {
			types.overlay_theme(&result, t)
			found = true
		}
	}
	return
}

// (Re)build the synthetic theme entries for composed key `key` ("a b").
install_composed_aspect :: proc(theme: ^map[string]types.Theme, key: string) {
	parts := strings.split(key, COMPOSED_ASPECT_SEP, context.temp_allocator)
	for suffix in COMPOSED_ASPECT_SUFFIXES {
		full := strings.concatenate({key, suffix}, context.temp_allocator)
		if full in theme {
			old_k, old_v := delete_key(theme, full)
			delete(old_k)
			if len(old_v.font) > 0 do delete(old_v.font)
		}
		t, found := compose_theme_entry(theme^, parts, suffix)
		if !found do continue
		if len(t.font) > 0 do t.font = strings.clone(t.font)
		theme[strings.clone(full)] = t
	}
}

// Remember composed key `key` and make sure its theme entries exist.
register_composed_aspect :: proc(b: ^Bridge, key: string) {
	if key in b.composed_aspects do return
	b.composed_aspects[strings.clone(key)] = {}
	install_composed_aspect(&b.theme, key)
}

// Rebuild every known composed entry against the current b.theme. Called
// after redin_set_theme replaced the map.
reinstall_composed_aspects :: proc(b: ^Bridge) {
	for key in b.composed_aspects do install_composed_aspect(&b.theme, key)
}

// True for a synthetic entry ("a b", "a b#hover", ...) — used to keep
// them out of GET /aspects, which reports the app's theme.
is_composed_theme_key :: proc(b: ^Bridge, name: string) -> bool {
	if !strings.contains(name, COMPOSED_ASPECT_SEP) do return false
	for suffix in COMPOSED_ASPECT_SUFFIXES {
		if !strings.has_suffix(name, suffix) do continue
		if name[:len(name) - len(suffix)] in b.composed_aspects do return true
	}
	return false
}

// Free a theme map: every key and every entry's `font` are heap-owned.
free_theme_map :: proc(theme: ^map[string]types.Theme) {
	for k, v in theme {
		delete(k)
		if len(v.font) > 0 do delete(v.font)
	}
	delete(theme^)
	theme^ = nil
}

free_composed_aspects :: proc(b: ^Bridge) {
	for k in b.composed_aspects do delete(k)
	delete(b.composed_aspects)
	b.composed_aspects = nil
}

// Read a node's :aspect attribute. A keyword/string is returned as-is; a
// sequence of keywords (`[:a :b]`) becomes the composed key "a b" and is
// registered with g_bridge so its theme entries exist. A one-element list
// is the plain aspect. Non-string elements are ignored. The result is
// allocated with `allocator` (empty string = no aspect).
lua_get_aspect_field :: proc(
	L: ^Lua_State,
	index: i32,
	field: cstring,
	allocator := context.allocator,
) -> string {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if lua_isstring(L, -1) do return lua_clone_string(L, -1, allocator)
	if !lua_istable(L, -1) do return ""

	tbl := lua_gettop(L)
	parts := make([dynamic]string, context.temp_allocator)
	n := i32(lua_objlen(L, tbl))
	for i: i32 = 1; i <= n; i += 1 {
		lua_rawgeti(L, tbl, i)
		if lua_isstring(L, -1) {
			s := lua_tostring_str(L, -1)
			if len(s) > 0 && !strings.contains(s, COMPOSED_ASPECT_SEP) {
				append(&parts, strings.clone(s, context.temp_allocator))
			}
		}
		lua_pop(L, 1)
	}

	switch len(parts) {
	case 0:
		return ""
	case 1:
		return strings.clone(parts[0], allocator)
	}
	key := strings.join(parts[:], COMPOSED_ASPECT_SEP, allocator)
	if g_bridge != nil do register_composed_aspect(g_bridge, key)
	return key
}
