package bridge

import "core:sync"
import "core:testing"
import "../font"

// #277 L2: load_font_faces read the face name and path via the strlen-based
// lua_tostring_raw, truncating at the first NUL. A "dir\0/../../etc/x" path
// therefore reached validate_font_path pre-truncated to "dir" — passing the
// guard on bytes that are not the real Lua value — and went on to LoadFont.
// With NUL-preserving reads, validate_font_path sees the full bytes and
// rejects them (it refuses embedded NULs outright), so nothing is loaded
// or registered. Runs headless because the reject happens before any
// raylib call.

@(test)
test_load_font_faces_rejects_nul_path :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	rc := luaL_dostring(L, `return {myfont = {regular = "dir\0/../../etc/x"}}`)
	testing.expectf(t, rc == 0, "failed to build faces table (rc=%d)", rc)

	before := len(font.fonts)
	load_font_faces(L, lua_gettop(L))
	testing.expect_value(t, len(font.fonts), before)
}
