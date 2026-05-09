# Security audit fixes (#129) — design

## Goal

Address the mechanical findings from issue #129's security audit on a single branch (`fix/security-audit-129`) off `origin/main`. Six findings in scope: H2, H3, H4, H5, H7, L1. One commit per finding plus one for the Dependabot config.

Out of scope for this PR (deferred for later discussion):

- **H1** — `redin.http` / `redin.shell` fail-open defaults. Policy decision (secure-by-default vs scripting-toolkit posture); document or change separately.
- **H6** — cwd-relative `src/runtime/?.fnl` in `fennel.path`. Requires a source-tree-detection design.
- **H8** — single-threaded dev-server accept loop. Architectural; the audit explicitly classifies it as a hardening note, not a vulnerability.
- **L2 / L3** — IDN/case-sensitivity documentation deltas in the bridge API. Not a behavior change; can ride a docs commit later.

The redin trust model is unchanged. The dev-server perimeter (already addressed in #99) stays as-is. These are output-correctness, CI-hygiene, and small bug fixes.

## Fixes

### H2 — JSON encoder escapes U+0000–U+001F

`src/redin/bridge/json.odin:19-38`

Extend the `json_string` switch so every code point < 0x20 not already covered by `\n`, `\r`, `\t` is emitted as `\u00XX`. After the change, the encoder is RFC 8259 §7 compliant. Lua strings are byte sequences and may legitimately carry any byte; today `\b`, `\f`, `\v`, `\x00`–`\x07`, `\x0e`–`\x1f` fall through `strings.write_rune` and get written raw, which strict parsers (browser `JSON.parse`, Go `encoding/json`) reject.

```odin
json_string :: proc(b: ^strings.Builder, s: string) {
    strings.write_byte(b, '"')
    for c in s {
        switch c {
        case '"':  strings.write_string(b, `\"`)
        case '\\': strings.write_string(b, `\\`)
        case '\n': strings.write_string(b, `\n`)
        case '\r': strings.write_string(b, `\r`)
        case '\t': strings.write_string(b, `\t`)
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

`fmt` is already imported in the file. RFC 8259 allows both `\u00XX` and `\u00xx`; lower-case matches what Python's `json` and JS `JSON.stringify` emit. Note that 0x08 (`\b`) and 0x0C (`\f`) get the generic `\u00XX` form rather than the dedicated `\b` / `\f` JSON shortcuts; both are valid per the spec, and the single-fallthrough rule keeps the switch small. The 5-character `\u00XX` output is also what the audit explicitly recommended.

### H3 — `null` for non-finite floats

`src/redin/bridge/json.odin:40-46`

Bail out at the top of `json_number` for non-finite values:

```odin
import "core:math"

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

`math.is_finite` is false for both NaN and ±Inf, covering all three pathological cases in one branch. Emitting `null` matches the convention already used by Python's `json` (with `allow_nan=False`) and Go's `encoding/json` (which errors instead, but `null` is the closest valid-JSON approximation).

`is_nan` / `is_inf` are already used for input validation in `handle_post_click`, `handle_post_input_mouse_move`, and `handle_post_resize` (`devserver.odin`). This applies the same discipline on the output side.

### H4 — Delete `agent_escape_json`, route through `json_string`

`src/redin/bridge/devserver.odin:1010-1052`

After H2 lands, `json_string` is a strict superset of `agent_escape_json` (which only covers `"`, `\`, `\n`, `\t` — even less than the original `json_string`, missing `\r`). Replace each call site:

```odin
// before
fmt.sbprintf(b, `"%s"`, agent_escape_json(val))

// after
json_string(b, val)
```

Three call sites in `emit_agent_content` (input, image, default-leaf). After the rewrite, delete the `agent_escape_json` proc. No new tests — H2's coverage protects all three paths.

### H5 — Pin third-party Actions to commit SHAs + Dependabot

`.github/workflows/release.yml`, `.github/workflows/test.yml`, `.github/dependabot.yml` (new)

Per the audit's stated triage, pin the higher-priority third-party actions only. `actions/*` is first-party and lower-risk, so it stays on `@vN` for now.

Two actions to pin to commit SHAs (with trailing `# vN.M.K` comments so a human reading the YAML still sees the version):

| Action | Current ref | New form |
|---|---|---|
| `laytan/setup-odin` | `@v2` | `@<sha>  # v2.x.y` |
| `softprops/action-gh-release` | `@v3` | `@<sha>  # v3.x.y` |

The two commit SHAs are resolved at implementation time from the latest tag matching the major version; the resolution command and the resulting SHAs are recorded in the implementation plan.

Add `.github/dependabot.yml` so the SHAs do not silently rot:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
```

GitHub-Actions dependabot updates SHAs in place and includes a comment with the upstream tag, which fits the comment convention above.

`actions/checkout`, `actions/upload-artifact`, `actions/download-artifact` remain on `@v6` / `@v7` / `@v8`. Pinning the rest is a follow-up; doing it here would expand scope past "mechanical fixes only."

### H7 — `lua_tolstring` in `redin_log`

`src/redin/bridge/bridge.odin:354`

`string(cstring)` in Odin slices to the first NUL byte. Lua strings are byte sequences, so logging them via `cstring` round-trips cleanly only when no NUL is present. Use Lua's length-aware accessor:

```odin
case LUA_TSTRING:
    n: uint
    s := lua_tolstring(L, i, &n)
    fmt.print(string(([^]u8)(s)[:n]))
```

`lua_tolstring`'s signature in `lua_api.odin` is `proc(L, index, len: ^uint) -> cstring`, so no new imports are needed; `cstring` cast to multi-pointer + slice is the canonical idiom for length-aware byte handling in Odin.

Note: other Lua → Odin read paths in the bridge (e.g. `agent_node_attr_string`, `lua_tostring_raw` callers) use the same `string(cstring)` truncation pattern. The audit didn't flag those — they read attribute names and other constrained payloads where embedded NULs are not expected. Fixing `redin_log` is sufficient; the broader sweep is deferred. No new test — `redin_log` is exercised by every UI smoke test that logs a string.

### L1 — Reject extra positional argv

`src/cmd/redin/main.odin:13-17`

Replace the silent overwrite loop with a strict arity check:

```odin
main :: proc() {
    if len(os.args) != 2 {
        fmt.eprintln("usage: redin <app.fnl|app.lua>")
        os.exit(2)
    }
    cfg: redin.Config
    cfg.app = os.args[1]
    // ... existing REDIN_TRACK_MEM block ...
    redin.run(cfg)
}
```

Exit code 2 is the conventional Unix usage-error code (matches `getopt(3)` and most CLIs). The "no flags accepted" stance is consistent with #114, which removed all runtime flags in favor of compile-time `-define`s.

Verification: `./build/redin` exits 2 (no app); `./build/redin a.fnl b.fnl` exits 2 (extra arg); `./build/redin a.fnl` runs as before.

## Verification

Run after the last commit:

| Step | Command |
|---|---|
| Release build | `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin` |
| Bridge tests (incl. new `json_test.odin`) | `odin test src/redin/bridge -define:ODIN_TEST_THREADS=1` |
| Fennel runtime tests | `luajit test/lua/runner.lua test/lua/test_*.fnl` |
| UI integration (covers H4 under REDIN_AGENT) | `./build-dev.sh -define:REDIN_AGENT=true && bash test/ui/run-all.sh --headless` |
| L1 manual | `./build/redin; echo $?` → 2; `./build/redin x y; echo $?` → 2 |
| Workflow lint | `gh workflow view release.yml` and `gh workflow view test.yml` after pushing the branch (visual sanity check that the YAML still parses) |

## Test plan

New file `src/redin/bridge/json_test.odin`. Coverage:

- Existing escapes (`"`, `\`, `\n`, `\r`, `\t`) still round-trip — regression guard.
- Each control byte 0x00–0x1F not in the existing-escape set encodes as `\u00xx` with lower-case hex (verify a representative sample: 0x00, 0x07, 0x08 / `\b`, 0x0b / `\v`, 0x0c / `\f`, 0x0e, 0x1f).
- 0x20 (' ') and above pass through unchanged.
- `json_number(NaN)` → `null`. `json_number(+Inf)` → `null`. `json_number(-Inf)` → `null`. `json_number(0.0)` → `0`. `json_number(-1.5)` → `-1.5`.

H4 is not separately tested — its correctness reduces to "json_string is correct," which H2's tests cover.

H7 has no dedicated unit test; the integration-test surface logs strings every frame, and the failure mode (silent truncation) does not produce an observable regression in any current assertion. Adding a NUL-bearing log line to one of the existing UI tests would add coverage but expand scope; we accept the visual-inspection risk.

L1 is verified manually as above.

## Documentation updates

None. The JSON encoder change is bug-fix-shaped (output becomes more correct, not different in shape). L1 documents undocumented behavior that no consumer should be relying on. Skill files and `docs/` reference contracts that are unchanged.

## Risk / rollback

All six fixes are independent and individually revertable. The biggest behavioral change is L1: any caller invoking `redin` with extra positional args today silently picked up the last one; from this PR forward they exit 2. No known caller does this — the framework only takes one app file.

H2 / H3 affect output bytes for previously-malformed inputs. Any consumer relying on raw control bytes in JSON output (none known) would see a behavior change.

H4 / H5 / H7 are pure refactors with no observable behavior change for legitimate inputs.

## Commit ordering

1. `feat(bridge): json_string escapes U+0000–U+001F (#129 H2)`
2. `feat(bridge): json_number emits null for NaN/Inf (#129 H3)`
3. `refactor(bridge): drop agent_escape_json, reuse json_string (#129 H4)`
4. `ci: pin third-party Actions to commit SHAs (#129 H5)`
5. `ci: add Dependabot config for github-actions (#129 H5)`
6. `fix(bridge): use lua_tolstring in redin_log to preserve NULs (#129 H7)`
7. `fix(cli): reject extra positional argv (#129 L1)`
