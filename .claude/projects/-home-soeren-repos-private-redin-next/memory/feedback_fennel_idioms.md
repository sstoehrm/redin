---
name: Fennel idioms for LuaJIT
description: Fennel/Lua 5.1 patterns discovered during dataflow implementation - avoid raw lua escapes, reserved words, use flag patterns
type: feedback
---

When writing Fennel targeting LuaJIT (Lua 5.1):

- `match` is a Fennel keyword -- never use as a variable name
- `lua "return ?default"` raw escapes are fragile -- Fennel `?`-prefixed names aren't valid Lua identifiers. Use flag-variable patterns instead (e.g., `missing` flag in `get-in`, `bail` flag in `dissoc-in`)
- Hyphenated names like `get-in` must use `tset _G "get-in"` for global assignment -- `set _G.get-in` is invalid Fennel
- `(length tbl)` is Fennel for `#tbl`
- Fennel's `for` loop doesn't support `break` -- use flag variables for early exit
- Fennel's single-file `fennel.lua` has a recursive-require issue -- test runner uses a sentinel workaround (documented in `test/lua/runner.lua`)

**Why:** Discovered during dataflow engine implementation. Plan code used `lua` escapes that failed at runtime.
**How to apply:** Use these patterns in all future Fennel implementation plans and code.
