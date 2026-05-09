# Security Audit (#129) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the six in-scope mechanical findings from issue #129 (H2, H3, H4, H5, H7, L1) on branch `fix/security-audit-129` (already created off `origin/main`; spec already committed).

**Architecture:** Seven sequential commits, one per finding (H5 splits into pin + Dependabot). TDD where applicable (H2/H3 add a new `json_test.odin`); H4 is a refactor protected by H2's tests; H7 and L1 are small bug fixes verified via existing test coverage and manual exit-code checks; H5 is a CI-only change.

**Tech Stack:** Odin (compiler 2026-04 nightly via laytan/setup-odin), LuaJIT (statically linked from `vendor/luajit`), Babashka for UI tests, `gh` CLI for resolving GitHub Actions commit SHAs.

---

## File Map

| File | Action | Why |
|---|---|---|
| `src/redin/bridge/json.odin` | Modify | H2 (extend `json_string` switch), H3 (`json_number` non-finite branch), `core:math` import |
| `src/redin/bridge/json_test.odin` | Create | H2/H3 unit coverage |
| `src/redin/bridge/devserver.odin` | Modify | H4 (drop `agent_escape_json`, swap call sites) |
| `src/redin/bridge/bridge.odin` | Modify | H7 (`redin_log` length-aware string read) |
| `src/cmd/redin/main.odin` | Modify | L1 (strict argv arity) |
| `.github/workflows/release.yml` | Modify | H5 (pin `laytan/setup-odin`, `softprops/action-gh-release` to SHAs) |
| `.github/workflows/test.yml` | Modify | H5 (pin `laytan/setup-odin` to SHA in two jobs) |
| `.github/dependabot.yml` | Create | H5 (weekly github-actions updates) |

---

## Task 1: H2 — JSON encoder escapes U+0000–U+001F

**Files:**
- Create: `src/redin/bridge/json_test.odin`
- Modify: `src/redin/bridge/json.odin` (add `core:fmt` import if absent; extend `json_string` switch)

- [ ] **Step 1: Verify the existing `json.odin` imports**

```bash
sed -n '1,10p' src/redin/bridge/json.odin
```

Expected: `core:strconv`, `core:strings`, `core:unicode/utf8`, `base:runtime`. Note whether `core:fmt` is already present — if not, you'll add it in Step 4.

- [ ] **Step 2: Write the failing test**

Create `src/redin/bridge/json_test.odin` with the following content. The expected-output strings use raw literals (backticks); inside an Odin raw string `\\u` is two literal characters (backslash + u), which is exactly what the encoder must emit.

```odin
package bridge

// Tests for the JSON encoder primitives in json.odin.
// Issue #129 H2: json_string must escape U+0000-U+001F per RFC 8259 §7.
// Issue #129 H3: json_number must emit `null` for NaN / +Inf / -Inf.

import "core:math"
import "core:strings"
import "core:testing"

@(test)
test_json_string_existing_escapes :: proc(t: ^testing.T) {
	// Regression: the five pre-existing escapes still work.
	cases := [][2]string{
		{"\"",   `"\""`},
		{"\\",   `"\\"`},
		{"\n",   `"\n"`},
		{"\r",   `"\r"`},
		{"\t",   `"\t"`},
		{"hi",   `"hi"`},
		{"",     `""`},
	}
	for c in cases {
		b := strings.builder_make(context.temp_allocator)
		json_string(&b, c[0])
		testing.expect_value(t, strings.to_string(b), c[1])
	}
}

@(test)
test_json_string_control_bytes_escape :: proc(t: ^testing.T) {
	// Per RFC 8259 §7, all U+0000-U+001F must be escaped. Bytes not
	// covered by \\n / \\r / \\t fall through to \\u00XX (lower-case hex).
	cases := [][2]string{
		{"\x00", `"\u0000"`},
		{"\x01", `"\u0001"`},
		{"\x07", `"\u0007"`},
		{"\x08", `"\u0008"`}, // \b in C; emitted as \u0008 here
		{"\x0b", `"\u000b"`},
		{"\x0c", `"\u000c"`}, // \f in C; emitted as \u000c here
		{"\x0e", `"\u000e"`},
		{"\x1f", `"\u001f"`},
	}
	for c in cases {
		b := strings.builder_make(context.temp_allocator)
		json_string(&b, c[0])
		testing.expect_value(t, strings.to_string(b), c[1])
	}
}

@(test)
test_json_string_high_bytes_pass_through :: proc(t: ^testing.T) {
	// 0x20 (space) and above are not escaped.
	b := strings.builder_make(context.temp_allocator)
	json_string(&b, " A~")
	testing.expect_value(t, strings.to_string(b), `" A~"`)
}

```

- [ ] **Step 3: Run the test suite, confirm new tests fail**

Run:

```bash
odin test src/redin/bridge -define:ODIN_TEST_THREADS=1
```

Expected: `test_json_string_existing_escapes`, `test_json_string_high_bytes_pass_through` PASS; `test_json_string_control_bytes_escape` FAIL — the current encoder writes the raw control byte; we expect `\u00XX` text.

If everything passes, the test is wrong, not the code — re-check the expected strings.

- [ ] **Step 4: Modify `src/redin/bridge/json.odin`**

If `core:fmt` is not in the import block, add it:

```odin
import "core:fmt"
```

Replace the `json_string` proc body's `case:` arm so the full proc reads:

```odin
json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if c < 0x20 {
				fmt.sbprintf(b, `\u%04x`, i32(c))
			} else {
				strings.write_rune(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}
```

The format string `` `\u%04x` `` is a raw string literal (backticks) so the leading `\u` is emitted literally; only `%04x` is consumed by `fmt`.

- [ ] **Step 5: Run tests, confirm all pass**

```bash
odin test src/redin/bridge -define:ODIN_TEST_THREADS=1
```

Expected: all `test_json_string_*` tests PASS. Other bridge tests (`test_find_header_value_*`, etc.) should also still pass.

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/json.odin src/redin/bridge/json_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): json_string escapes U+0000-U+001F (#129 H2)

Per RFC 8259 §7 all control bytes below 0x20 must be escaped. The
prior switch only covered \n, \r, \t and let other control bytes
fall through to write_rune raw, producing JSON that strict parsers
reject (browser JSON.parse, Go encoding/json). Lua strings are byte
sequences and may legitimately carry any byte, so /state, /aspects,
and /frames could emit invalid JSON to dev-server clients.

The fallthrough now emits \u00XX (lower-case hex) for any code point
< 0x20 not already covered by a dedicated escape. 0x08 / 0x0c get
the generic \u00XX form rather than the JSON-specific \b / \f
shortcuts; both are valid per RFC 8259.

Adds src/redin/bridge/json_test.odin covering the existing escapes
(regression), the new control-byte cases, and a high-byte
pass-through.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: H3 — `json_number` emits `null` for NaN / Inf

**Files:**
- Modify: `src/redin/bridge/json.odin` (add `core:math` import; `json_number` non-finite guard)
- Modify: `src/redin/bridge/json_test.odin` (append cases)

- [ ] **Step 1: Append failing tests to `src/redin/bridge/json_test.odin`**

Add at the end of the existing file (`core:math` is already imported from Task 1):

```odin
@(test)
test_json_number_finite :: proc(t: ^testing.T) {
	cases := []struct{ in: f64, out: string }{
		{0.0,    "0"},
		{1.0,    "1"},
		{-1.5,   "-1.5"},
		{42.0,   "42"},
		{1e10,   "1e10"},
	}
	for c in cases {
		b := strings.builder_make(context.temp_allocator)
		json_number(&b, c.in)
		testing.expect_value(t, strings.to_string(b), c.out)
	}
}

@(test)
test_json_number_non_finite_emits_null :: proc(t: ^testing.T) {
	non_finite := []f64{math.nan_f64(), math.inf_f64(1), math.inf_f64(-1)}
	for n in non_finite {
		b := strings.builder_make(context.temp_allocator)
		json_number(&b, n)
		testing.expect_value(t, strings.to_string(b), "null")
	}
}
```

- [ ] **Step 2: Run tests, confirm `test_json_number_non_finite_emits_null` fails**

```bash
odin test src/redin/bridge -define:ODIN_TEST_THREADS=1
```

Expected: `test_json_number_finite` PASS; `test_json_number_non_finite_emits_null` FAIL with body containing `NaN`, `+Inf`, or `Inf`.

- [ ] **Step 3: Modify `src/redin/bridge/json.odin`**

Add `core:math` to the imports if not present:

```odin
import "core:math"
```

Replace `json_number` so the full proc reads:

```odin
json_number :: proc(b: ^strings.Builder, n: f64) {
	if !math.is_finite(n) {
		strings.write_string(b, "null")
		return
	}
	buf: [64]u8
	s := strconv.write_float(buf[:], n, 'g', -1, 64)
	for c in s {
		if c != '+' do strings.write_byte(b, u8(c))
	}
}
```

`math.is_finite` returns false for both NaN and ±Inf, so the single guard covers all three cases.

- [ ] **Step 4: Run tests, confirm all pass**

```bash
odin test src/redin/bridge -define:ODIN_TEST_THREADS=1
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/json.odin src/redin/bridge/json_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): json_number emits null for NaN/Inf (#129 H3)

strconv.write_float emits "NaN", "Inf", "-Inf" for non-finite floats,
none of which are valid JSON. A Fennel app whose state contains a
NaN (e.g. 0/0, math.huge) silently corrupts the /state response.

Bail at the top of json_number for non-finite values and emit `null`
instead. Mirrors the is_nan / is_inf input checks already in place
in handle_post_click and handle_post_input_mouse_move on the
dev-server's input side.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: H4 — drop `agent_escape_json`, route through `json_string`

**Files:**
- Modify: `src/redin/bridge/devserver.odin` (delete proc + replace 3 call sites in `emit_agent_content`)

- [ ] **Step 1: Replace the three call sites in `emit_agent_content`**

Open `src/redin/bridge/devserver.odin`. Find `emit_agent_content`. Three lines currently read:

```odin
fmt.sbprintf(b, `"%s"`, agent_escape_json(val))
```

Replace each with:

```odin
json_string(b, val)
```

After the change, the surrounding lines look like:

```odin
case "input":
	val := agent_node_attr_string(L, "value")
	json_string(b, val)
case "image":
	val := agent_node_attr_string(L, "src")
	json_string(b, val)
```

…and at the bottom of the proc:

```odin
case:
	lua_rawgeti(L, -1, 3)
	val := ""
	if lua_isstring(L, -1) do val = string(lua_tostring_raw(L, -1))
	lua_pop(L, 1)
	json_string(b, val)
```

- [ ] **Step 2: Delete the `agent_escape_json` proc**

Delete the proc immediately above `emit_agent_content`:

```odin
agent_escape_json :: proc(s: string) -> string {
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
```

- [ ] **Step 3: Verify no other call sites**

```bash
rg -n 'agent_escape_json' src/
```

Expected: no output. (If anything matches, fix it before committing.)

- [ ] **Step 4: Build**

```bash
./build-dev.sh -define:REDIN_AGENT=true
```

Expected: exits 0; produces `build/redin`.

- [ ] **Step 5: Run the agent UI test suite**

```bash
bash test/ui/run-all.sh --headless
```

Expected: all UI tests pass, including `test_agent.bb` (since binary was built with REDIN_AGENT). If `xvfb-run` isn't installed locally, run windowed instead: `bash test/ui/run-all.sh`.

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
refactor(bridge): drop agent_escape_json, reuse json_string (#129 H4)

agent_escape_json's switch only covered ", \, \n, \t — even less
than the original json_string. After #129 H2 made json_string
strict about U+0000-U+001F, json_string is a strict superset.

Replace the three call sites in emit_agent_content with direct
json_string calls (json_string also writes the surrounding quotes,
so the manual fmt.sbprintf wrapper is gone). Delete the now-unused
agent_escape_json proc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: H5a — Pin third-party Actions to commit SHAs

**Files:**
- Modify: `.github/workflows/release.yml` (1× `laytan/setup-odin`, 1× `softprops/action-gh-release`)
- Modify: `.github/workflows/test.yml` (2× `laytan/setup-odin`)

- [ ] **Step 1: Resolve commit SHAs and version tags**

```bash
SETUP_ODIN_SHA=$(gh api repos/laytan/setup-odin/commits/v2 --jq '.sha')
GH_RELEASE_SHA=$(gh api repos/softprops/action-gh-release/commits/v3 --jq '.sha')
SETUP_ODIN_TAG=$(gh api repos/laytan/setup-odin/releases/latest --jq '.tag_name')
GH_RELEASE_TAG=$(gh api repos/softprops/action-gh-release/releases/latest --jq '.tag_name')
echo "laytan/setup-odin@${SETUP_ODIN_SHA}  # ${SETUP_ODIN_TAG}"
echo "softprops/action-gh-release@${GH_RELEASE_SHA}  # ${GH_RELEASE_TAG}"
```

If `gh` is not authenticated, run `gh auth status` first. Fallback for SHA-only resolution: `git ls-remote https://github.com/laytan/setup-odin v2 | awk '{print $1}'`.

Record the four values for use in Steps 2–3. Treat the angle-bracket placeholders below (`<SETUP_ODIN_SHA>`, `<SETUP_ODIN_TAG>`, etc.) as substitutions — copy the actual values into the YAML.

- [ ] **Step 2: Edit `.github/workflows/release.yml`**

Find the line `uses: laytan/setup-odin@v2` (currently in the `build` job). Replace with:

```yaml
        uses: laytan/setup-odin@<SETUP_ODIN_SHA>  # <SETUP_ODIN_TAG>
```

Find the line `uses: softprops/action-gh-release@v3` (in the `release` job). Replace with:

```yaml
        uses: softprops/action-gh-release@<GH_RELEASE_SHA>  # <GH_RELEASE_TAG>
```

- [ ] **Step 3: Edit `.github/workflows/test.yml`**

Two occurrences of `uses: laytan/setup-odin@v2` (in the `test` and `test-agent` jobs). Replace both with:

```yaml
        uses: laytan/setup-odin@<SETUP_ODIN_SHA>  # <SETUP_ODIN_TAG>
```

- [ ] **Step 4: Confirm only the intended Actions changed**

```bash
git diff .github/workflows/
```

Expected: changes only to `laytan/setup-odin` (3 occurrences) and `softprops/action-gh-release` (1 occurrence). `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact` remain on `@vN` per the audit's stated triage.

- [ ] **Step 5: Validate YAML parses**

```bash
python3 -c 'import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print("ok")' \
  .github/workflows/release.yml .github/workflows/test.yml
```

Expected: `ok`. (Or `yamllint` if installed. The push to GitHub will be the canonical lint pass; this is a local sanity check.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml .github/workflows/test.yml
git commit -m "$(cat <<'EOF'
ci: pin third-party Actions to commit SHAs (#129 H5)

`v`-tagged Action refs are mutable: a maintainer of the underlying
repo (or a compromised account) can ship arbitrary code through
them. The release job has `permissions: contents: write` and runs
softprops/action-gh-release, so a compromise could publish
trojaned tarballs.

Pin the two third-party Actions the audit flagged as higher
priority to immutable commit SHAs. Trailing `# vX.Y.Z` comments
preserve human readability. actions/* (first-party, lower risk per
the audit) stay on @vN for now; broaden later if needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: H5b — Add Dependabot config

**Files:**
- Create: `.github/dependabot.yml`

- [ ] **Step 1: Create `.github/dependabot.yml`**

Write the following content:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
```

- [ ] **Step 2: Validate YAML parses**

```bash
python3 -c 'import yaml; yaml.safe_load(open(".github/dependabot.yml")); print("ok")'
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add .github/dependabot.yml
git commit -m "$(cat <<'EOF'
ci: add Dependabot config for github-actions (#129 H5)

Pinning third-party Actions to commit SHAs (prior commit) freezes
them at audit time — but those SHAs need to advance when upstream
cuts security or feature releases. Dependabot's github-actions
ecosystem opens a PR each week with the new SHA and preserves the
trailing `# vX.Y.Z` comment, so the readable version tag stays in
sync.

Limit open PRs to 5 to keep noise low; can revisit if the project
takes on more workflow surface area.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: H7 — `lua_tolstring` in `redin_log`

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (LUA_TSTRING case in `redin_log`)

- [ ] **Step 1: Locate the call site**

```bash
rg -n 'redin_log :: proc' src/redin/bridge/bridge.odin
```

Then read the surrounding 20 lines to confirm the LUA_TSTRING arm is what currently does `fmt.print(string(lua_tostring_raw(L, i)))`.

- [ ] **Step 2: Modify the LUA_TSTRING arm**

In `src/redin/bridge/bridge.odin`, find:

```odin
case LUA_TSTRING:
	fmt.print(string(lua_tostring_raw(L, i)))
```

Replace with:

```odin
case LUA_TSTRING:
	n: uint
	s := lua_tolstring(L, i, &n)
	fmt.print(string(([^]u8)(s)[:n]))
```

`lua_tolstring`'s signature in `src/redin/bridge/lua_api.odin` is `proc(L, index, len: ^uint) -> cstring`, so no new imports are needed. The `[^]u8` cast is the canonical Odin idiom for treating a `cstring` as a length-aware byte slice.

- [ ] **Step 3: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exits 0.

- [ ] **Step 4: Run UI smoke tests**

`redin_log` is exercised by every UI test that logs a string — running smoke covers the regression surface.

```bash
./build-dev.sh
bash test/ui/run-all.sh --headless
```

Expected: all UI tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
fix(bridge): use lua_tolstring in redin_log to preserve NULs (#129 H7)

string(cstring) in Odin slices to the first NUL byte. Lua strings
are byte sequences and may legitimately contain NULs, so logging
them via cstring truncated content silently. Switch to the
length-aware lua_tolstring + multi-pointer slice idiom.

Other Lua → Odin read paths in the bridge (agent_node_attr_string
and similar) have the same truncation pattern but read constrained
payloads (attribute names) where embedded NULs are not expected;
flagging redin_log specifically because it logs arbitrary user
strings. Broader sweep deferred.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: L1 — Reject extra positional argv

**Files:**
- Modify: `src/cmd/redin/main.odin` (replace argv loop with strict arity check)

- [ ] **Step 1: Modify `main`**

Open `src/cmd/redin/main.odin`. Replace the `for arg in os.args[1:] { cfg.app = arg }` block with a strict arity check. The full `main` proc should read:

```odin
main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: redin <app.fnl|app.lua>")
		os.exit(2)
	}
	cfg: redin.Config
	cfg.app = os.args[1]

	when REDIN_TRACK_MEM {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		fmt.eprintln("Memory tracking enabled (REDIN_TRACK_MEM)")
		// Assign at proc scope. Odin's `context` is block-scoped: setting
		// context.allocator inside an `if` block reverts when the block
		// ends, so the tracker never reaches `redin.run` and reports zero
		// activity. Compile-time `when` inlines its body at proc scope, so
		// this assignment IS at effective proc scope when the flag is true.
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	redin.run(cfg)
}
```

The `REDIN_TRACK_MEM` block is unchanged from the prior version of `main`.

- [ ] **Step 2: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exits 0.

- [ ] **Step 3: Manual verification**

```bash
./build/redin; echo "exit=$?"
./build/redin examples/kitchen-sink.fnl extra-arg; echo "exit=$?"
```

Expected: both runs print `usage: redin <app.fnl|app.lua>` to stderr and exit `2`. Then verify the happy path still runs (Ctrl-C after the window appears):

```bash
./build/redin examples/kitchen-sink.fnl
```

Expected: window opens normally.

- [ ] **Step 4: Commit**

```bash
git add src/cmd/redin/main.odin
git commit -m "$(cat <<'EOF'
fix(cli): reject extra positional argv (#129 L1)

The previous loop iterated os.args[1:] and overwrote cfg.app on
every iteration, so ./build/redin a.fnl b.fnl silently ran b.fnl —
or, more confusingly, ./build/redin main.fnl --foo tried to load a
file literally named --foo.

Replace with a strict arity check: exit 2 ("usage error" per
getopt(3) convention) when args != 2. Consistent with #114 having
removed all runtime flags.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Final verification

- [ ] **Step 1: Release-stripped build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exits 0.

- [ ] **Step 2: Bridge unit tests**

```bash
odin test src/redin/bridge -define:ODIN_TEST_THREADS=1
```

Expected: all tests PASS, including the new `test_json_*` cases.

- [ ] **Step 3: Fennel runtime tests**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: 133 tests pass (matches CLAUDE.md's stated count; if higher, that's fine — just no failures).

- [ ] **Step 4: UI integration tests with REDIN_AGENT (covers H4)**

```bash
./build-dev.sh -define:REDIN_AGENT=true
bash test/ui/run-all.sh --headless
```

Expected: all UI suites pass, including `test_agent.bb`.

- [ ] **Step 5: Confirm commit log matches plan**

```bash
git log --oneline origin/main..HEAD
```

Expected (8 commits including the spec):

```
fix(cli): reject extra positional argv (#129 L1)
fix(bridge): use lua_tolstring in redin_log to preserve NULs (#129 H7)
ci: add Dependabot config for github-actions (#129 H5)
ci: pin third-party Actions to commit SHAs (#129 H5)
refactor(bridge): drop agent_escape_json, reuse json_string (#129 H4)
feat(bridge): json_number emits null for NaN/Inf (#129 H3)
feat(bridge): json_string escapes U+0000-U+001F (#129 H2)
docs(spec): security audit #129 — mechanical fixes
```

(`git log` is reverse-chronological; the spec commit is at the bottom.)

- [ ] **Step 6: Stop and hand back to user**

Do NOT push the branch or open a PR autonomously. Report the verification results back; the user decides when to push and create the PR.
