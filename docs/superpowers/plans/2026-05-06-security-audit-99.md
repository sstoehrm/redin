# Security audit fixes (#99) — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land all eight findings from the bridge / devserver / http / shell security audit (issue #99) on a single branch, with TDD coverage and matching docs.

**Architecture:** Permissive defaults plus opt-in hardening setters (`set_http_whitelist`, `set_shell_env_allowlist`) added to `bridge/api.odin`. New required defaults baked into the bridge effect path (HTTP/shell timeouts, shell output cap, scheme reject, header CRLF reject, redirect disable, Content-Length overflow guard, fatal token-write).

**Tech Stack:** Odin (host), LuaJIT + Fennel (scripting), `lib:odin-http` (vendored submodule, do not modify in this plan), Babashka (UI tests).

**Branch:** `fix/security-audit-99`, branched off `origin/main` (already created).

**Spec:** [`docs/superpowers/specs/2026-05-06-security-audit-99-design.md`](../specs/2026-05-06-security-audit-99-design.md) — read this before starting.

**Spec→plan unit alignment:** the spec said `:timeout` is "seconds" for `:http` and `:shell`. The existing Fennel `:http` effect handler already passes the timeout in **milliseconds** (default `30000`, see `src/runtime/effect.fnl:100`). The plan aligns with the existing convention: **`:timeout` is milliseconds (integer), default `30000`**. `:max-output` for `:shell` stays MiB (integer), default `16`.

**File layout (created or modified by this plan):**

- Create: `src/redin/bridge/shell_test.odin` — new unit tests for `execute_shell` (output cap, env allowlist, timeout)
- Modify: `src/redin/bridge/http_client.odin` — timeouts, in-flight cap, scheme guard, whitelist, header CRLF validation, disable redirects
- Modify: `src/redin/bridge/shell.odin` — output cap, timeout, env allowlist
- Modify: `src/redin/bridge/bridge.odin` — read new args from Lua in `redin_http` / `redin_shell`
- Modify: `src/redin/bridge/api.odin` — add `set_http_whitelist`, `set_shell_env_allowlist`, package-level state
- Modify: `src/redin/bridge/devserver.odin` — Content-Length overflow guard, fatal token write
- Modify: `src/redin/bridge/devserver_headers_test.odin` — overflow tests
- Modify: `src/redin/bridge/devserver_write_test.odin` — token-write fatal test
- Modify: `src/redin/bridge/http_client_test.odin` — scheme/whitelist/CRLF/redirect tests
- Modify: `src/runtime/effect.fnl` — add `:max-output` and `:timeout` to `:shell` effect handler; pass through to `redin_shell`
- Modify: `docs/core-api.md`, `docs/reference/effects.md`, `docs/reference/native-bridge.md`, `docs/reference/dev-server.md`, `.claude/skills/redin-dev/SKILL.md`

**Conventions across all tasks:**

- Each task is TDD: write the failing test, run it red, implement, run green, commit.
- Test runner for bridge unit tests: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`. Add `-define:ODIN_TEST_THREADS=1` if any new test exhibits a race; do not add it preemptively.
- Commit messages use Conventional Commits with the issue scope, e.g. `fix(bridge): ...` and end with the framework's standard co-authored-by line.
- Do not modify `lib/odin-http/` (it is a submodule). All HTTP timeout / redirect work happens in our wrapper layer in `bridge/http_client.odin`.

---

## Task 1: M5 — Reject CRLF / NUL in HTTP request headers

**Files:**
- Modify: `src/redin/bridge/http_client.odin` (helper + check at request boundary)
- Modify: `src/redin/bridge/http_client_test.odin` (add cases)

The `redin.http` effect lets the app set arbitrary headers. Today they are passed verbatim to odin-http with no validation. A header value containing `\r\n` could split the request. Fix: reject any header key or value containing `\r`, `\n`, or `\x00` at the boundary, fail the call with an error response.

- [ ] **Step 1: Add failing test for CRLF rejection in header value**

In `src/redin/bridge/http_client_test.odin`, append:

```odin
@(test)
test_http_header_value_rejects_crlf :: proc(t: ^testing.T) {
	headers := make(map[string]string)
	headers["X-Smuggle"] = strings.clone("evil\r\nHost: attacker")
	defer {
		for k, v in headers { delete(k); delete(v) }
		delete(headers)
	}
	headers["X-Smuggle"] = strings.clone("evil\r\nHost: attacker")

	req := Http_Request{
		id      = strings.clone("crlf-test"),
		url     = strings.clone("http://127.0.0.1:1/"),
		method  = strings.clone("GET"),
		headers = headers,
	}
	defer {
		delete(req.id); delete(req.url); delete(req.method)
	}

	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}

	testing.expect(t, got.status == 0, "expected synthesized error status 0")
	testing.expect(t, strings.contains(got.error_msg, "invalid character"),
		fmt.tprintf("expected 'invalid character' in error_msg, got %q", got.error_msg))
}
```

Add a near-duplicate `test_http_header_key_rejects_nul` that puts `\x00` in a key.

- [ ] **Step 2: Run the test, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: the new tests fail because the call attempts a real connection to `127.0.0.1:1` and returns a connect error rather than the validation error.

- [ ] **Step 3: Add the helper and the boundary check**

In `src/redin/bridge/http_client.odin`, near the top of the file (below the `HTTP_MAX_BODY` const), add:

```odin
@(private = "file")
header_safe :: proc(s: string) -> bool {
	for r in s {
		if r == '\r' || r == '\n' || r == 0 do return false
	}
	return true
}
```

In `execute_http_request`, **before** the `for k, v in req.headers` loop that calls `http.headers_set`, validate:

```odin
for k, v in req.headers {
	if !header_safe(k) || !header_safe(v) {
		response.status = 0
		response.error_msg = strings.clone("http header contains invalid character")
		return response
	}
}
```

- [ ] **Step 4: Run the tests, expect green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/http_client.odin src/redin/bridge/http_client_test.odin
git commit -m "$(cat <<'EOF'
fix(bridge): reject CRLF/NUL in HTTP request headers (#99 M5)

Adds a per-call validation step before request submission. Header
keys or values containing \r, \n, or \x00 fail the call with a
synthesized error response (status 0, error "http header contains
invalid character"). Closes the request-smuggling vector flagged in
issue #99.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: L1 — Reject malformed Content-Length on the dev server

**Files:**
- Modify: `src/redin/bridge/devserver.odin` (`find_content_length` + caller at line ~267)
- Modify: `src/redin/bridge/devserver_headers_test.odin`

Today `find_content_length` accumulates digits into an `int` with no overflow check. Inputs longer than 19 digits (or with arithmetic overflow) silently wrap. The caller's `cl > MAX_BODY` check doesn't catch a wrapped negative value. Fix: cap the digit count to 12 and return `-1` on overflow; reject negative results in the caller with `400`.

- [ ] **Step 1: Add failing tests**

In `src/redin/bridge/devserver_headers_test.odin`, append:

```odin
@(test)
test_find_content_length_overflow_returns_negative :: proc(t: ^testing.T) {
	// 19 digits — well above 12-digit cap; current code silently wraps.
	headers := "POST / HTTP/1.1\r\nContent-Length: 9999999999999999999\r\n"
	testing.expect(t, find_content_length(headers) < 0,
		"expected negative on overflow")
}

@(test)
test_find_content_length_normal :: proc(t: ^testing.T) {
	headers := "POST / HTTP/1.1\r\nContent-Length: 1024\r\n"
	testing.expect_value(t, find_content_length(headers), 1024)
}

@(test)
test_find_content_length_zero :: proc(t: ^testing.T) {
	headers := "GET / HTTP/1.1\r\nContent-Length: 0\r\n"
	testing.expect_value(t, find_content_length(headers), 0)
}
```

- [ ] **Step 2: Run tests, expect failure on the overflow case**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: `test_find_content_length_overflow_returns_negative` fails (returns a wrapped positive value).

- [ ] **Step 3: Patch `find_content_length`**

In `src/redin/bridge/devserver.odin`, replace the digit-accumulation loop in `find_content_length` (currently around lines 530–537) with:

```odin
n := 0
digits := 0
for c in val {
	if c >= '0' && c <= '9' {
		digits += 1
		if digits > 12 { return -1 }
		n = n*10 + int(c - '0')
	} else {
		break
	}
}
return n
```

(The 12-digit cap = up to `999_999_999_999`, ~1 TiB — far above `MAX_BODY` and well below `int` overflow on any supported platform.)

- [ ] **Step 4: Patch the caller to honour negative**

In `src/redin/bridge/devserver.odin` around line 267, after `cl := find_content_length(...)` but before the `cl > MAX_BODY` check, add:

```odin
if cl < 0 {
	resp := "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	net.send_tcp(client, transmute([]u8)resp)
	net.close(client)
	break  // (or continue, depending on local control flow — match the existing too_large path)
}
```

Verify the local control flow against the existing `too_large` branch a few lines below; the negative-CL branch should match its structure (send 400, close, exit the inner loop the same way).

- [ ] **Step 5: Run tests, expect green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/devserver.odin src/redin/bridge/devserver_headers_test.odin
git commit -m "$(cat <<'EOF'
fix(bridge): guard Content-Length parser against overflow (#99 L1)

find_content_length now caps digit count at 12 and returns -1 on
overflow. The caller responds 400 Bad Request when the parser
returns a negative value. Prevents the silent integer wrap that
could produce a small positive cl from a 99999... header and
sneak past the MAX_BODY check.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: L2 — Make token / port file write failure fatal in dev mode

**Files:**
- Modify: `src/redin/bridge/devserver.odin` (~lines 172–180)
- Modify: `src/redin/bridge/devserver_write_test.odin`

Today, if `write_private_no_follow` fails for `.redin-token` or `.redin-port`, the dev server logs a warning and keeps running. The token still works in memory, but local clients (test runners, the user's own `curl`) silently fail to authenticate. Fix: make a write failure abort dev-server startup so the user gets a clear error instead of a stream of inscrutable 401s.

- [ ] **Step 1: Add failing test**

In `src/redin/bridge/devserver_write_test.odin`, append a test that proves the write-failure branch aborts startup. Reuse the existing approach from the file (likely involves placing a non-regular file at the target path). Minimum sketch:

```odin
@(test)
test_devserver_aborts_on_token_write_fail :: proc(t: ^testing.T) {
	// Place a directory at TOKEN_FILE so write_private_no_follow refuses.
	// Save & restore the working dir; use a temp dir to keep CI tidy.
	// Assert ds.running == false after devserver_init returns.
	// (Implementation depends on the existing helpers in this file —
	// follow the existing pattern.)
}
```

If the existing test file already has a helper for chdir-into-temp + cleanup, reuse it. If not, write the smallest one needed (a temp dir + `os.chdir` with deferred restore).

- [ ] **Step 2: Run the test, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: the new test fails because today `ds.running` stays true.

- [ ] **Step 3: Patch the write block**

In `src/redin/bridge/devserver.odin` around lines 171–177, replace:

```odin
port_str := fmt.tprintf("%d", bound_port)
if !write_private_no_follow(PORT_FILE, transmute([]u8)port_str) {
	fmt.eprintfln("Warning: could not write %s (refused to follow non-regular path)", PORT_FILE)
}
if !write_private_no_follow(TOKEN_FILE, transmute([]u8)ds.auth_token) {
	fmt.eprintfln("Warning: could not write %s (refused to follow non-regular path)", TOKEN_FILE)
}
```

with:

```odin
port_str := fmt.tprintf("%d", bound_port)
if !write_private_no_follow(PORT_FILE, transmute([]u8)port_str) {
	fmt.eprintfln("redin: failed to write %s; aborting dev server", PORT_FILE)
	ds.running = false
	return
}
if !write_private_no_follow(TOKEN_FILE, transmute([]u8)ds.auth_token) {
	fmt.eprintfln("redin: failed to write %s; aborting dev server", TOKEN_FILE)
	// Clean up the port file we just wrote so it doesn't lie about a live server.
	os.remove(PORT_FILE)
	ds.running = false
	return
}
```

(The port-file cleanup on token failure prevents `.redin-port` from advertising a server that never finished standing up.)

- [ ] **Step 4: Run tests, expect green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/devserver.odin src/redin/bridge/devserver_write_test.odin
git commit -m "$(cat <<'EOF'
fix(bridge): abort dev server on token-file write failure (#99 L2)

Previously logged a warning and kept running, which produced silent
401 responses on every subsequent request because local clients
read .redin-token to authenticate. Now write failure prints a clear
"failed to write" line and exits devserver_init, after cleaning up
.redin-port if it was just written.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: L3 — Stop following HTTP redirects automatically

**Files:**
- Modify: `src/redin/bridge/http_client.odin` (`execute_http_request`)
- Modify: `src/redin/bridge/http_client_test.odin`

The existing `http_client.request` (vendored, do not modify) does not document a redirect-follow option, but its current implementation reads as if it returns the first response without auto-redirecting. **Verify** during implementation by reading `lib/odin-http/client/client.odin` more thoroughly; if it does follow redirects internally, the fix is to switch our wrapper to a more direct call (e.g. dial + send + parse without the auto-follow path) or to pass a 0-hop option if one exists.

If the library already does not follow redirects, this task reduces to writing the regression test that pins the behaviour.

- [ ] **Step 1: Inspect odin-http for a redirect-follow option**

```bash
grep -n -i "redirect\|follow\|location" lib/odin-http/client/client.odin
```

Document the finding in the commit message of this task. Three outcomes:
1. odin-http never follows redirects → only test is needed.
2. odin-http follows redirects via a flag we can pass → set the flag to false in `request_init` (or an equivalent struct-field assignment) before `request`.
3. odin-http follows redirects unconditionally → in `execute_http_request`, replace the call to `http_client.request(...)` with a more granular sequence that returns the first response without recursing on `Location`. This is the most invasive case; if you reach it, write a one-line note in the spec ("L3 deferred — needs upstream work") and stop here.

- [ ] **Step 2: Add the test**

In `src/redin/bridge/http_client_test.odin`, append:

```odin
@(test)
test_http_redirect_not_followed :: proc(t: ^testing.T) {
	resp := "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil {
		testing.fail_now(t, "could not bind a mock server port")
	}
	defer mock_stop(m)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("redirect-test"),
		url = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }

	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}

	testing.expect_value(t, got.status, 302)
}
```

- [ ] **Step 3: Run the test**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected behaviour depends on the outcome of Step 1. If the library already returns 302 without following, the test passes immediately and you are done after committing it as a regression. If the library does follow, the test will fail (the `mock_start` only answers once, so the second hop will hang or error) and Step 4 needs the fix described above.

- [ ] **Step 4: If needed, disable redirect-follow**

Apply the change identified in Step 1. The exact line depends on what the library exposes — do not invent a field name. If the only path is invasive (case 3 above), document and skip per the Step 1 instructions.

- [ ] **Step 5: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/http_client.odin src/redin/bridge/http_client_test.odin
git commit -m "$(cat <<'EOF'
fix(bridge): pin HTTP redirect non-following (#99 L3)

Adds a regression test that asserts a 302 response is returned to
the caller as-is (status 302, Location header in response.headers)
rather than transparently followed. Library inspection in Step 1
of this task established whether any wrapper change was needed;
the commit either pins existing behaviour with a test, or adds a
small wrapper-level redirect-disable, depending on the outcome.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: M4 part A — Reject non-http(s) URL schemes

**Files:**
- Modify: `src/redin/bridge/http_client.odin` (early in `execute_http_request`)
- Modify: `src/redin/bridge/http_client_test.odin`

- [ ] **Step 1: Add failing tests**

In `src/redin/bridge/http_client_test.odin`, append:

```odin
@(test)
test_http_rejects_ftp_scheme :: proc(t: ^testing.T) {
	req := Http_Request{
		id = strings.clone("scheme-1"),
		url = strings.clone("ftp://example.com/"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 0)
	testing.expect(t, strings.contains(got.error_msg, "scheme"),
		fmt.tprintf("expected 'scheme' in error_msg, got %q", got.error_msg))
}

@(test)
test_http_rejects_file_scheme :: proc(t: ^testing.T) {
	req := Http_Request{
		id = strings.clone("scheme-2"),
		url = strings.clone("file:///etc/passwd"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 0)
	testing.expect(t, strings.contains(got.error_msg, "scheme"),
		"expected scheme rejection error_msg")
}

@(test)
test_http_accepts_uppercase_https :: proc(t: ^testing.T) {
	// Just confirms scheme matching is case-insensitive — no real connect.
	// We expect a connect error (status 0, error_msg contains "Request failed"
	// or similar), NOT the scheme-rejection error_msg.
	req := Http_Request{
		id = strings.clone("scheme-3"),
		url = strings.clone("HTTPS://127.0.0.1:1/"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect(t, !strings.contains(got.error_msg, "scheme"),
		"HTTPS (uppercase) must not be rejected as scheme")
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 3: Add scheme guard**

At the top of `execute_http_request` in `src/redin/bridge/http_client.odin` (after the response init, before any odin-http calls), add:

```odin
// Scheme guard. Always-on; not opt-out. M4 from issue #99.
{
	colon := strings.index_byte(req.url, ':')
	scheme := colon < 0 ? "" : strings.to_lower(req.url[:colon], context.temp_allocator)
	if scheme != "http" && scheme != "https" {
		response.status = 0
		response.error_msg = strings.clone("http scheme must be http or https")
		return response
	}
}
```

- [ ] **Step 4: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/http_client.odin src/redin/bridge/http_client_test.odin
git commit -m "$(cat <<'EOF'
fix(bridge): reject non-http(s) URL schemes in redin.http (#99 M4 A)

Always-on scheme check at the start of execute_http_request. URLs
whose scheme is not http or https (case-insensitive) fail with a
synthesized error response. Closes the file://, ftp://, gopher://
exfiltration vectors flagged in the audit; complements the opt-in
destination whitelist that follows in part B.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: M4 part B — HTTP destination whitelist + public bridge API

**Files:**
- Modify: `src/redin/bridge/api.odin` (new public proc + package state + mutex)
- Modify: `src/redin/bridge/http_client.odin` (whitelist check inside `execute_http_request`)
- Modify: `src/redin/bridge/http_client_test.odin` (whitelist tests)

Add a public proc `bridge.set_http_whitelist(allow: []string)` that stores a clone of the input behind a package-level mutex. When the whitelist is unset (default), any host is allowed. When set, the request's host must match a hostname literal (case-insensitive) or a CIDR (IPv4 or IPv6, only matched against IP-literal hosts). On rejection, return a synthesized error response that names the rejected host.

- [ ] **Step 1: Add failing tests**

In `src/redin/bridge/http_client_test.odin`, append (use the mock server from Task 4 / existing tests):

```odin
@(test)
test_http_whitelist_allows_listed_host :: proc(t: ^testing.T) {
	resp := "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil { testing.fail_now(t, "could not bind mock") }
	defer mock_stop(m)

	set_http_whitelist([]string{"127.0.0.1"})
	defer set_http_whitelist(nil)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("wl-1"), url = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 200)
}

@(test)
test_http_whitelist_blocks_unlisted_host :: proc(t: ^testing.T) {
	set_http_whitelist([]string{"example.com"})
	defer set_http_whitelist(nil)

	req := Http_Request{
		id = strings.clone("wl-2"),
		url = strings.clone("http://127.0.0.1:1/"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 0)
	testing.expect(t, strings.contains(got.error_msg, "127.0.0.1"),
		fmt.tprintf("expected rejected host name in error, got %q", got.error_msg))
	testing.expect(t, strings.contains(got.error_msg, "whitelist"),
		"expected 'whitelist' in error message")
}

@(test)
test_http_whitelist_hostname_case_insensitive :: proc(t: ^testing.T) {
	set_http_whitelist([]string{"Example.COM"})
	defer set_http_whitelist(nil)

	req := Http_Request{
		id = strings.clone("wl-3"),
		url = strings.clone("http://example.com/"),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	// Connect will likely fail (no DNS in CI for example.com), but the
	// failure must NOT be a whitelist rejection. We assert the absence
	// of the whitelist error string.
	testing.expect(t, !strings.contains(got.error_msg, "whitelist"),
		"hostname compare should be case-insensitive")
}

@(test)
test_http_whitelist_cidr_match :: proc(t: ^testing.T) {
	resp := "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	m := mock_start(resp)
	if m == nil { testing.fail_now(t, "could not bind mock") }
	defer mock_stop(m)

	set_http_whitelist([]string{"127.0.0.0/8"})
	defer set_http_whitelist(nil)

	url := fmt.tprintf("http://127.0.0.1:%d/", m.port)
	req := Http_Request{
		id = strings.clone("wl-4"), url = strings.clone(url),
		method = strings.clone("GET"),
	}
	defer { delete(req.id); delete(req.url); delete(req.method) }
	got := execute_http_request(req)
	defer {
		delete(got.body); delete(got.error_msg)
		for k, v in got.headers { delete(k); delete(v) }
		delete(got.headers)
	}
	testing.expect_value(t, got.status, 200)
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

(Compile failures are expected since `set_http_whitelist` doesn't exist yet.)

- [ ] **Step 3: Add the public API + state to `api.odin`**

At the bottom of `src/redin/bridge/api.odin`, append:

```odin
// ---------------------------------------------------------------------------
// Outbound HTTP destination whitelist (issue #99 M4)
// ---------------------------------------------------------------------------
//
// When unset (default), redin.http accepts any http(s) destination.
// When set, the URL host must match either a hostname literal
// (case-insensitive) or a CIDR (IPv4 or IPv6, applied only to
// IP-literal hosts). Apps opt in by calling this setter at startup
// from app.odin (--native projects) or via a registered cfunc.

@(private)
g_http_whitelist:       []string
@(private)
g_http_whitelist_mutex: sync.Mutex

set_http_whitelist :: proc(allow: []string) {
	sync.lock(&g_http_whitelist_mutex)
	defer sync.unlock(&g_http_whitelist_mutex)

	for s in g_http_whitelist do delete(s)
	delete(g_http_whitelist)
	g_http_whitelist = nil

	if allow == nil do return

	cloned := make([]string, len(allow))
	for s, i in allow do cloned[i] = strings.clone(s)
	g_http_whitelist = cloned
}

// http_whitelist_check returns ("", true) if allowed, ("<rejected host>", false)
// otherwise. host must already be the URL host (no port, no scheme).
@(private)
http_whitelist_check :: proc(host: string) -> (rejected: string, ok: bool) {
	sync.lock(&g_http_whitelist_mutex)
	defer sync.unlock(&g_http_whitelist_mutex)

	if g_http_whitelist == nil do return "", true

	host_lower := strings.to_lower(host, context.temp_allocator)
	for entry in g_http_whitelist {
		// CIDR entry?
		if strings.contains(entry, "/") {
			if cidr_match(host, entry) do return "", true
			continue
		}
		// Hostname literal — case-insensitive exact match.
		entry_lower := strings.to_lower(entry, context.temp_allocator)
		if host_lower == entry_lower do return "", true
	}
	return host, false
}

// cidr_match: parse `cidr` ("a.b.c.d/N" or IPv6) and test against `host`.
// host is matched only if it is an IP literal; hostnames return false.
@(private)
cidr_match :: proc(host: string, cidr: string) -> bool {
	addr := net.parse_ip4_address(host)
	if addr == 0 {
		// Not an IPv4 literal — try IPv6 path.
		addr6, ok6 := net.parse_ip6_address(host)
		if !ok6 do return false
		// IPv6 CIDR matching — minimal impl: parse, mask, compare.
		return cidr6_match(addr6, cidr)
	}
	return cidr4_match(addr, cidr)
}
```

Add helpers `cidr4_match` and `cidr6_match` in the same file. The IPv4 version splits `cidr` on `/`, parses the prefix as `net.IP4_Address`, parses the bits, builds a mask, and does the bitwise compare. IPv6 mirrors with `net.IP6_Address`. (Confirm the exact `net` package API names during implementation; `core:net` exposes parsing primitives.)

If `core:net` does not have a CIDR helper out of the box, add one as a private file-scope helper in `api.odin` rather than pulling in a third-party dependency. Keep it ~20 lines.

You will also need to add `import "core:net"` and `import "core:sync"` at the top of `api.odin` if not already present.

- [ ] **Step 4: Wire the whitelist check into `execute_http_request`**

In `src/redin/bridge/http_client.odin`, immediately **after** the scheme guard added in Task 5 and **before** anything that mutates request state, parse the URL host and check the whitelist:

```odin
// Whitelist guard. Opt-in via bridge.set_http_whitelist. M4 from issue #99.
{
	host := url_host(req.url) // see helper below
	if rejected, ok := http_whitelist_check(host); !ok {
		response.status = 0
		response.error_msg = fmt.aprintf("host %s not in http whitelist", rejected)
		return response
	}
}
```

Add `url_host` as a `@(private = "file")` helper in `http_client.odin`:

```odin
@(private = "file")
url_host :: proc(url: string) -> string {
	// "http://host:port/path" → "host"
	idx := strings.index(url, "://")
	if idx < 0 do return ""
	rest := url[idx + 3:]
	end := len(rest)
	for i in 0 ..< len(rest) {
		c := rest[i]
		if c == '/' || c == '?' || c == '#' { end = i; break }
	}
	host := rest[:end]
	// strip port
	if colon := strings.last_index_byte(host, ':'); colon >= 0 {
		// Skip the last-colon strip if this is a bracketed IPv6 host.
		if !strings.has_prefix(host, "[") {
			host = host[:colon]
		}
	}
	// Strip IPv6 brackets if present.
	if strings.has_prefix(host, "[") && strings.has_suffix(host, "]") {
		host = host[1 : len(host) - 1]
	}
	return host
}
```

- [ ] **Step 5: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/api.odin src/redin/bridge/http_client.odin src/redin/bridge/http_client_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): opt-in HTTP destination whitelist (#99 M4 B)

Adds bridge.set_http_whitelist([]string) to api.odin. When unset
(default), redin.http accepts any http(s) host. When set, the URL
host must match a hostname literal (case-insensitive) or a CIDR
(IPv4 or IPv6, only matched against IP-literal hosts).

Rejected calls return a synthesized error response naming the
rejected host. Hostnames are not resolved at validation time; the
app is trusted, so this is a self-protection tool, not anti-hostile-
app defense.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: M3 — Shell env allowlist + public bridge API

**Files:**
- Modify: `src/redin/bridge/api.odin` (add `set_shell_env_allowlist` + state + mutex)
- Modify: `src/redin/bridge/shell.odin` (filter env in `execute_shell` when allowlist set)
- Create: `src/redin/bridge/shell_test.odin`

When the allowlist is set, child processes spawned by `redin.shell` see only the env vars whose keys are in the list. When unset (default), they inherit the full parent env (current behaviour).

- [ ] **Step 1: Create `shell_test.odin` with a failing allowlist test**

```odin
package bridge

import "core:strings"
import "core:testing"

@(test)
test_shell_env_allowlist_filters :: proc(t: ^testing.T) {
	// Use uname-like env-printer command. /usr/bin/env exists on Linux/macOS.
	set_shell_env_allowlist([]string{"PATH"})
	defer set_shell_env_allowlist(nil)

	cmd := []string{strings.clone("/usr/bin/env")}
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id = strings.clone("env-1"),
		cmd = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	// stdout should contain PATH=... but no other typical user env vars.
	testing.expect(t, strings.contains(got.stdout, "PATH="),
		"expected PATH in env output")
	testing.expect(t, !strings.contains(got.stdout, "AWS_"),
		"expected AWS_ vars filtered out by allowlist")
}

@(test)
test_shell_env_allowlist_unset_full_passthrough :: proc(t: ^testing.T) {
	set_shell_env_allowlist(nil)

	cmd := []string{strings.clone("/usr/bin/env")}
	defer { for s in cmd do delete(s); delete(cmd) }
	req := Shell_Request{
		id = strings.clone("env-2"),
		cmd = cmd,
		stdin = strings.clone(""),
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}
	// PATH is reliably present in the test runner's env.
	testing.expect(t, strings.contains(got.stdout, "PATH="),
		"expected PATH= in default-passthrough env output")
}
```

If `/usr/bin/env` is not portable in the test environment, fall back to a small Odin-side env-printing test command — but Linux is the supported platform so `/usr/bin/env` is fine.

- [ ] **Step 2: Run, expect compile failure (`set_shell_env_allowlist` undefined)**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 3: Add public API + state to `api.odin`**

```odin
// ---------------------------------------------------------------------------
// Shell env allowlist (issue #99 M3)
// ---------------------------------------------------------------------------
//
// When unset (default), child processes inherit the full parent env.
// When set, only keys present in the allowlist are passed through.
// Exact match, case-sensitive.

@(private)
g_shell_env_allowlist:       []string
@(private)
g_shell_env_allowlist_mutex: sync.Mutex

set_shell_env_allowlist :: proc(allow: []string) {
	sync.lock(&g_shell_env_allowlist_mutex)
	defer sync.unlock(&g_shell_env_allowlist_mutex)

	for s in g_shell_env_allowlist do delete(s)
	delete(g_shell_env_allowlist)
	g_shell_env_allowlist = nil

	if allow == nil do return
	cloned := make([]string, len(allow))
	for s, i in allow do cloned[i] = strings.clone(s)
	g_shell_env_allowlist = cloned
}

// shell_env_filtered returns the filtered env, or nil if the allowlist is
// unset (caller should leave Process_Desc.env = nil for full passthrough).
// Returned slice is owned by the caller (free each entry + the slice itself).
@(private)
shell_env_filtered :: proc() -> []string {
	sync.lock(&g_shell_env_allowlist_mutex)
	defer sync.unlock(&g_shell_env_allowlist_mutex)

	if g_shell_env_allowlist == nil do return nil

	out := make([dynamic]string, 0, len(g_shell_env_allowlist))
	for entry in os.environ() {
		// `entry` is "KEY=VALUE"; extract KEY.
		eq := strings.index_byte(entry, '=')
		if eq < 0 do continue
		key := entry[:eq]
		for allow in g_shell_env_allowlist {
			if key == allow {
				append(&out, strings.clone(entry))
				break
			}
		}
	}
	return out[:]
}
```

Add `import "core:os"` to `api.odin` if not already there.

- [ ] **Step 4: Wire the filter into `execute_shell`**

In `src/redin/bridge/shell.odin`, modify the `Process_Desc` construction (line 137):

```odin
filtered_env := shell_env_filtered()
defer if filtered_env != nil {
	for s in filtered_env do delete(s)
	delete(filtered_env)
}

desc := os.Process_Desc {
	command = req.cmd,
	stdout  = stdout_w,
	stderr  = stderr_w,
	stdin   = stdin_r,
	env     = filtered_env,  // nil = inherit parent env (current behaviour)
}
```

Verify: `os.Process_Desc.env` accepts `nil` to mean "inherit". This is the Odin core convention; if `env` is a non-nillable type, set it only inside an `if filtered_env != nil` branch and use a separate `desc` constant.

- [ ] **Step 5: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/api.odin src/redin/bridge/shell.odin src/redin/bridge/shell_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): opt-in shell env allowlist (#99 M3)

Adds bridge.set_shell_env_allowlist([]string) to api.odin. When
unset (default), spawned children inherit the full parent env
(current behaviour). When set, children see only the keys present
in the allowlist; everything else is stripped.

Apps that shell out to credential-aware tools (gh, aws, git) still
work by default. Apps that want hardening opt in by listing the
keys they actually need.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: M1 part A — HTTP request timeout (with pending registry)

**Files:**
- Modify: `src/redin/bridge/http_client.odin` (`Http_Request`, `Http_Client`, `http_client_request`, `http_thread_proc`, `http_client_poll`)
- Modify: `src/redin/bridge/bridge.odin` (`redin_http` reads new arg)
- Modify: `src/redin/bridge/http_client_test.odin`

The Fennel `:http` effect handler already passes a `timeout` (ms) as the 6th argument to `redin_http`, but Odin currently ignores arg 6. Read it; if absent or ≤0 use `HTTP_DEFAULT_TIMEOUT_MS = 30000`. Implement the deadline using a per-request entry in a "pending" registry on `Http_Client`. Each frame, `http_client_poll` checks for entries whose deadline has passed and synthesizes a timeout error response, removing the entry. The actual worker thread is allowed to continue (we cannot cancel `http_client.request` from outside without modifying the vendored library); when it eventually finishes, it looks up its registry entry and discards the result if the entry is gone.

- [ ] **Step 1: Add a failing test using a slow mock**

In `src/redin/bridge/http_client_test.odin`, add:

```odin
@(private = "file")
slow_mock_serve :: proc(m: ^Mock_Server) {
	defer sync.sema_post(&m.done)
	client, _, err := net.accept_tcp(m.sock)
	if err != nil do return
	defer net.close(client)
	// Read the request, then sleep instead of responding.
	buf: [4096]u8
	total := 0
	for total < len(buf) {
		n, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || n <= 0 do break
		total += n
		if strings.contains(string(buf[:total]), "\r\n\r\n") do break
	}
	time.sleep(2 * time.Second)
}

@(test)
test_http_timeout_fires :: proc(t: ^testing.T) {
	m := new(Mock_Server)
	for p in 18900 ..< 19000 {
		s, e := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = p})
		if e == nil { m.sock = s; m.port = p; break }
	}
	if m.port == 0 { testing.fail_now(t, "no port") }
	m.thread = thread.create_and_start_with_poly_data(m, slow_mock_serve, context)
	defer mock_stop(m)

	hc: Http_Client
	http_client_init(&hc)
	defer http_client_destroy(&hc)

	req := Http_Request{
		id = strings.clone("timeout-1"),
		url = strings.clone(fmt.tprintf("http://127.0.0.1:%d/", m.port)),
		method = strings.clone("GET"),
		timeout_ms = 200,  // 200 ms; mock sleeps 2 s
	}
	http_client_request(&hc, req)

	// Poll for up to 1 s to pick up the timeout result.
	deadline := time.time_add(time.now(), 1 * time.Second)
	results: [dynamic]Http_Response
	defer { for &r in results do http_response_destroy(&r); delete(results) }
	for time.diff(time.now(), deadline) > 0 {
		http_client_poll(&hc, &results)
		if len(results) > 0 do break
		time.sleep(50 * time.Millisecond)
	}

	testing.expect(t, len(results) == 1, "expected one timeout result")
	if len(results) == 1 {
		testing.expect_value(t, results[0].status, 0)
		testing.expect(t, strings.contains(results[0].error_msg, "timeout"),
			fmt.tprintf("expected 'timeout' in error_msg, got %q", results[0].error_msg))
	}
}
```

Add `import "core:time"` if not already imported.

- [ ] **Step 2: Run, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 3: Add `timeout_ms` + pending registry**

In `src/redin/bridge/http_client.odin`:

```odin
HTTP_DEFAULT_TIMEOUT_MS :: 30_000

Http_Request :: struct {
	id:         string,
	url:        string,
	method:     string,
	headers:    map[string]string,
	body:       string,
	timeout_ms: int,
}

@(private = "file")
Pending_Http :: struct {
	id:       string,         // owned copy; freed when the entry is removed
	deadline: time.Time,
}

Http_Client :: struct {
	results:       [dynamic]Http_Response,
	results_mutex: sync.Mutex,
	pending:       map[string]Pending_Http,
	pending_mutex: sync.Mutex,
}
```

Update `http_client_request`:

```odin
http_client_request :: proc(hc: ^Http_Client, req: Http_Request) {
	timeout := req.timeout_ms <= 0 ? HTTP_DEFAULT_TIMEOUT_MS : req.timeout_ms

	sync.lock(&hc.pending_mutex)
	hc.pending[strings.clone(req.id)] = Pending_Http{
		id       = strings.clone(req.id),
		deadline = time.time_add(time.now(), time.Duration(timeout) * time.Millisecond),
	}
	sync.unlock(&hc.pending_mutex)

	data := new(Http_Thread_Data)
	data.client = hc
	data.request = req
	thread.create_and_start_with_data(data, http_thread_proc, self_cleanup = true)
}
```

Update `http_thread_proc` to drop the result if the entry was removed by the timeout sweep:

```odin
http_thread_proc :: proc(raw_data_ptr: rawptr) {
	data := cast(^Http_Thread_Data)raw_data_ptr
	response := execute_http_request(data.request)

	keep := false
	sync.lock(&data.client.pending_mutex)
	if entry, ok := data.client.pending[data.request.id]; ok {
		// Owned id key — free it before removing from the map.
		delete_key(&data.client.pending, data.request.id)
		delete(entry.id)
		keep = true
	}
	sync.unlock(&data.client.pending_mutex)

	if keep {
		sync.lock(&data.client.results_mutex)
		append(&data.client.results, response)
		sync.unlock(&data.client.results_mutex)
	} else {
		// Entry was already replaced by a timeout. Discard the result.
		http_response_destroy(&response)
	}

	http_request_destroy(&data.request)
	free(data)
}
```

Update `http_client_poll` to sweep pending entries and synthesize timeout responses:

```odin
http_client_poll :: proc(hc: ^Http_Client, results: ^[dynamic]Http_Response) {
	now := time.now()
	timed_out: [dynamic]string  // owned ids
	defer delete(timed_out)

	sync.lock(&hc.pending_mutex)
	for id, entry in hc.pending {
		if time.diff(now, entry.deadline) <= 0 {
			append(&timed_out, strings.clone(id))
		}
	}
	for id in timed_out {
		if entry, ok := hc.pending[id]; ok {
			delete_key(&hc.pending, id)
			delete(entry.id)
		}
	}
	sync.unlock(&hc.pending_mutex)

	if len(timed_out) > 0 {
		sync.lock(&hc.results_mutex)
		for id in timed_out {
			r := Http_Response{
				id        = id,  // ownership transfers; freed by destroy
				status    = 0,
				error_msg = strings.clone("http timeout exceeded"),
				headers   = make(map[string]string),
			}
			append(&hc.results, r)
		}
		sync.unlock(&hc.results_mutex)
	} else {
		// IDs aren't transferred above; nothing to clean.
	}

	sync.lock(&hc.results_mutex)
	defer sync.unlock(&hc.results_mutex)
	for &r in hc.results do append(results, r)
	clear(&hc.results)
}
```

Update `http_client_destroy` to free the pending map.

In `src/redin/bridge/bridge.odin` `redin_http` (line ~438), after reading args 1–5, read arg 6:

```odin
if lua_isnumber(L, 6) {
	req.timeout_ms = int(lua_tonumber(L, 6))
}
```

(Default of 0 here triggers the default in `http_client_request`.)

- [ ] **Step 4: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/http_client.odin src/redin/bridge/bridge.odin src/redin/bridge/http_client_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): HTTP request timeout with pending registry (#99 M1 A)

Adds Http_Request.timeout_ms (default 30000 ms via the Fennel
effect handler, also defaulted on the Odin side). Each in-flight
request is tracked in a pending registry on Http_Client; the
poll loop synthesizes a timeout error response and removes the
entry once the deadline has passed. The worker thread checks the
registry on completion and discards the result if it has been
replaced by a timeout — the underlying http_client.request call
cannot be cancelled (vendored library), so the worker continues
in the background but its result is no longer surfaced.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: M1 part B — HTTP in-flight concurrency cap

**Files:**
- Modify: `src/redin/bridge/http_client.odin`
- Modify: `src/redin/bridge/http_client_test.odin`

Cap concurrent in-flight requests at 64. New requests beyond the cap fail synchronously with a synthesized error response.

- [ ] **Step 1: Add failing test**

```odin
@(test)
test_http_inflight_cap_rejects :: proc(t: ^testing.T) {
	hc: Http_Client
	http_client_init(&hc)
	defer http_client_destroy(&hc)

	// Spin up MAX_INFLIGHT_HTTP slow requests.
	m := new(Mock_Server)
	for p in 18900 ..< 19000 {
		s, e := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = p})
		if e == nil { m.sock = s; m.port = p; break }
	}
	if m.port == 0 { testing.fail_now(t, "no port") }
	m.thread = thread.create_and_start_with_poly_data(m, slow_mock_serve, context)
	defer mock_stop(m)

	// Submit MAX_INFLIGHT_HTTP requests + 1; the +1 must be rejected.
	for i in 0 ..< MAX_INFLIGHT_HTTP {
		req := Http_Request{
			id = strings.clone(fmt.tprintf("cap-%d", i)),
			url = strings.clone(fmt.tprintf("http://127.0.0.1:%d/", m.port)),
			method = strings.clone("GET"),
			timeout_ms = 5000,
		}
		http_client_request(&hc, req)
	}
	overflow := Http_Request{
		id = strings.clone("cap-over"),
		url = strings.clone(fmt.tprintf("http://127.0.0.1:%d/", m.port)),
		method = strings.clone("GET"),
		timeout_ms = 5000,
	}
	http_client_request(&hc, overflow)

	// Poll briefly for the rejected response.
	deadline := time.time_add(time.now(), 500 * time.Millisecond)
	results: [dynamic]Http_Response
	defer { for &r in results do http_response_destroy(&r); delete(results) }
	for time.diff(time.now(), deadline) > 0 {
		http_client_poll(&hc, &results)
		if len(results) >= 1 do break
		time.sleep(20 * time.Millisecond)
	}

	found := false
	for r in results {
		if r.id == "cap-over" && strings.contains(r.error_msg, "concurrent") {
			found = true; break
		}
	}
	testing.expect(t, found, "expected overflow request to be rejected with 'concurrent' error")
}
```

- [ ] **Step 2: Run, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 3: Implement the cap**

In `src/redin/bridge/http_client.odin`:

```odin
MAX_INFLIGHT_HTTP :: 64
```

In `http_client_request`, before doing anything else:

```odin
sync.lock(&hc.pending_mutex)
inflight := len(hc.pending)
sync.unlock(&hc.pending_mutex)

if inflight >= MAX_INFLIGHT_HTTP {
	r := Http_Response{
		id        = strings.clone(req.id),
		status    = 0,
		error_msg = strings.clone("too many concurrent http requests (cap 64)"),
		headers   = make(map[string]string),
	}
	sync.lock(&hc.results_mutex)
	append(&hc.results, r)
	sync.unlock(&hc.results_mutex)
	http_request_destroy(&req)
	return
}
```

Note: `req` is by value; `http_request_destroy` consumes its allocations. Adjust the signature to take `req` by value and `defer` the cleanup if cleaner — match the surrounding style.

- [ ] **Step 4: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/http_client.odin src/redin/bridge/http_client_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): cap concurrent HTTP requests at 64 (#99 M1 B)

Bounds in-flight HTTP threads at MAX_INFLIGHT_HTTP. A submission
beyond the cap fails synchronously with a synthesized error
response ('too many concurrent http requests (cap 64)'). Prevents
a runaway loop in app code from spawning unbounded threads and
exhausting host memory.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: M2 part A — Shell output cap

**Files:**
- Modify: `src/redin/bridge/shell.odin` (`Shell_Request`, `execute_shell`)
- Modify: `src/redin/bridge/bridge.odin` (`redin_shell` reads new arg)
- Modify: `src/runtime/effect.fnl` (`:shell` effect: pass `:max-output`)
- Modify: `src/redin/bridge/shell_test.odin`

Cap stdout+stderr at 16 MiB by default; per-call override via `:max-output N` (MiB) on the `:shell` map. On exceedance, kill the child, set `error_msg = "shell output exceeded N MiB cap"`, set `exit_code = -1`, and clear stdout/stderr.

- [ ] **Step 1: Add failing test**

In `src/redin/bridge/shell_test.odin`:

```odin
@(test)
test_shell_output_cap_kills_child :: proc(t: ^testing.T) {
	// `yes` runs forever; with a 1 MiB cap it should be killed quickly.
	cmd := []string{strings.clone("yes")}
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id = strings.clone("cap-1"),
		cmd = cmd,
		stdin = strings.clone(""),
		max_output_bytes = 1 * 1024 * 1024,
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	testing.expect_value(t, got.exit_code, -1)
	testing.expect(t, strings.contains(got.error_msg, "exceeded"),
		fmt.tprintf("expected 'exceeded' in error_msg, got %q", got.error_msg))
	testing.expect_value(t, len(got.stdout), 0)
	testing.expect_value(t, len(got.stderr), 0)
}
```

Add `import "core:fmt"` to the file if needed.

- [ ] **Step 2: Run, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 3: Add the field + the cap check**

In `src/redin/bridge/shell.odin`:

```odin
SHELL_DEFAULT_MAX_OUTPUT :: 16 * 1024 * 1024  // 16 MiB

Shell_Request :: struct {
	id:               string,
	cmd:              []string,
	stdin:            string,
	max_output_bytes: int,
}
```

In `execute_shell`, derive `cap`:

```odin
cap := req.max_output_bytes
if cap <= 0 do cap = SHELL_DEFAULT_MAX_OUTPUT
```

Modify the read loop. On each successful append, check the combined buffer size; on overflow, kill, clear, set error, break the loop:

```odin
killed := false
for !stdout_done || !stderr_done {
	if !stdout_done {
		n, err := os.read(stdout_r, read_buf[:])
		if err != nil || n <= 0 {
			stdout_done = true
		} else {
			append(&stdout_buf, ..read_buf[:n])
		}
	}
	if !stderr_done {
		n, err := os.read(stderr_r, read_buf[:])
		if err != nil || n <= 0 {
			stderr_done = true
		} else {
			append(&stderr_buf, ..read_buf[:n])
		}
	}
	if len(stdout_buf) + len(stderr_buf) > cap {
		os.process_kill(process)
		clear(&stdout_buf)
		clear(&stderr_buf)
		response.exit_code = -1
		response.error_msg = fmt.aprintf("shell output exceeded %d MiB cap", cap / (1024*1024))
		killed = true
		break
	}
}

if killed {
	// Reap the child to avoid a zombie.
	_, _ = os.process_wait(process)
	return response
}
```

Verify `os.process_kill` exists in the Odin core (it does as of recent versions); if not, replace with the platform-specific equivalent already used elsewhere in the codebase.

- [ ] **Step 4: Plumb through Lua → Fennel → bridge**

In `src/redin/bridge/bridge.odin` `redin_shell` (line ~931), after reading args 1–3:

```odin
if lua_isnumber(L, 4) {
	mb := int(lua_tonumber(L, 4))
	if mb > 0 do req.max_output_bytes = mb * 1024 * 1024
}
```

In `src/runtime/effect.fnl` `:shell` handler (line ~105), pass `:max-output` through:

```fennel
(M.reg-fx :shell
  (fn [params]
    (set next-shell-id (+ next-shell-id 1))
    (let [id (tostring next-shell-id)
          cmd (or params.cmd [])
          stdin (or params.stdin "")
          max-output (or params.max-output 16)]
      (tset pending-shell id {:on-success params.on-success
                              :on-error params.on-error})
      (when _G.redin_shell
        (_G.redin_shell id cmd stdin max-output)))))
```

- [ ] **Step 5: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
luajit test/lua/runner.lua test/lua/test_*.fnl
```

The Fennel tests should still pass — the new `:max-output` param has a default of 16, so existing test apps don't need updates.

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/shell.odin src/redin/bridge/bridge.odin src/runtime/effect.fnl src/redin/bridge/shell_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): cap shell stdout+stderr at 16 MiB (#99 M2 A)

Adds max_output_bytes to Shell_Request, default 16 MiB, per-call
override via :max-output N (MiB) on the :shell effect map. When
the combined buffer crosses the cap during the read loop, the
child is killed (and reaped), buffers are cleared, and the
response is returned with exit_code -1 and a descriptive error
message. No partial data is surfaced — the call simply fails.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: M2 part B — Shell timeout

**Files:**
- Modify: `src/redin/bridge/shell.odin`
- Modify: `src/redin/bridge/bridge.odin`
- Modify: `src/runtime/effect.fnl`
- Modify: `src/redin/bridge/shell_test.odin`

Per-call `:timeout` (ms) on `:shell`, default 30000 ms. On expiry, kill child, clear buffers, return error.

- [ ] **Step 1: Add failing test**

```odin
@(test)
test_shell_timeout_kills_child :: proc(t: ^testing.T) {
	// `sleep 60` should be killed by a 200 ms timeout.
	cmd := []string{strings.clone("sleep"), strings.clone("60")}
	defer { for s in cmd do delete(s); delete(cmd) }

	req := Shell_Request{
		id = strings.clone("to-1"),
		cmd = cmd,
		stdin = strings.clone(""),
		timeout_ms = 200,
	}
	defer { delete(req.id); delete(req.stdin) }

	got := execute_shell(req)
	defer {
		delete(got.id); delete(got.stdout); delete(got.stderr); delete(got.error_msg)
	}

	testing.expect_value(t, got.exit_code, -1)
	testing.expect(t, strings.contains(got.error_msg, "timeout"),
		fmt.tprintf("expected 'timeout' in error_msg, got %q", got.error_msg))
}
```

- [ ] **Step 2: Run, expect failure**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

- [ ] **Step 3: Add timeout field + deadline check**

```odin
SHELL_DEFAULT_TIMEOUT_MS :: 30_000

Shell_Request :: struct {
	id:               string,
	cmd:              []string,
	stdin:            string,
	max_output_bytes: int,
	timeout_ms:       int,
}
```

In `execute_shell`, after the cap derivation, derive the deadline:

```odin
timeout_ms := req.timeout_ms
if timeout_ms <= 0 do timeout_ms = SHELL_DEFAULT_TIMEOUT_MS
deadline := time.time_add(time.now(), time.Duration(timeout_ms) * time.Millisecond)
```

Set non-blocking reads on both pipes (using the platform's pipe fcntl call) so the read loop can poll without blocking. If non-blocking pipes are not straightforward in Odin core, fall back to a watchdog goroutine that sends SIGTERM at the deadline; the read loop notices the closed pipes and exits.

The simplest implementation: skip the watchdog goroutine and check the elapsed time inline at the top of each read-loop iteration. The downside is that an idle child (one that produces no output) won't be killed until the next read returns; with blocking reads that means the timeout fires only when output finally arrives or both pipes close. To make idle-child timeouts responsive, set `SO_RCVTIMEO` on each pipe fd via `setsockopt` (Linux) or use `fcntl(F_SETFL, O_NONBLOCK)` plus `poll`. Pick whichever is supported in `core:os` / `core:sys/linux` without inventing wrappers; if neither is straightforward, accept the "kills on next read" tradeoff and document it in a code comment above the loop.

In the read loop, on each iteration also check the elapsed time:

```odin
if time.diff(time.now(), deadline) <= 0 {
	os.process_kill(process)
	clear(&stdout_buf); clear(&stderr_buf)
	response.exit_code = -1
	response.error_msg = fmt.aprintf("shell timeout exceeded %d ms", timeout_ms)
	killed = true
	break
}
```

(Two paths to "killed = true" — output cap or timeout — both end with `os.process_wait` to reap, then return.)

Note: with blocking reads, the timeout check only fires between read returns. If the child writes nothing for 60 s and the timeout is 200 ms, the read won't return until something arrives. To make timeouts responsive on idle children: either set `SO_RCVTIMEO` on the pipe fds (Linux/macOS via `fcntl` or `setsockopt`), OR run the read loop on a separate goroutine and have the main thread sleep on a sema with timeout. **Pick the simpler approach during impl** and document the tradeoff in a code comment.

- [ ] **Step 4: Plumb through Lua → Fennel → bridge**

In `redin_shell`:

```odin
if lua_isnumber(L, 5) {
	ms := int(lua_tonumber(L, 5))
	if ms > 0 do req.timeout_ms = ms
}
```

In `effect.fnl` `:shell` handler:

```fennel
(let [...
      max-output (or params.max-output 16)
      timeout    (or params.timeout 30000)]
  ...
  (_G.redin_shell id cmd stdin max-output timeout))
```

- [ ] **Step 5: Run tests green**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
luajit test/lua/runner.lua test/lua/test_*.fnl
```

- [ ] **Step 6: Commit**

```bash
git add src/redin/bridge/shell.odin src/redin/bridge/bridge.odin src/runtime/effect.fnl src/redin/bridge/shell_test.odin
git commit -m "$(cat <<'EOF'
feat(bridge): shell timeout (#99 M2 B)

Adds timeout_ms to Shell_Request, default 30 000 ms, per-call
override via :timeout N (ms) on the :shell effect map. On expiry
the child is killed and reaped, buffers are cleared, and the
response is returned with exit_code -1 and a descriptive error
message. Together with the M2 A output cap this closes the
shell-side DoS vectors flagged in the audit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Documentation + skill updates

**Files:**
- Modify: `docs/core-api.md` (effect map fields, error shapes, dev-server 400 path)
- Modify: `docs/reference/effects.md` (`:http` and `:shell` keys)
- Modify: `docs/reference/native-bridge.md` (new public procs)
- Modify: `docs/reference/dev-server.md` (note 400 + fatal token write)
- Modify: `.claude/skills/redin-dev/SKILL.md` (effect-map fields + setters)

CLAUDE.md mandates docs land in the same commits as code, but the seven prior tasks each touch one finding and the doc text covers multiple findings. Bundle the doc updates here as one self-contained docs commit; the prior commits stand as code-with-tests, this one closes the contract.

- [ ] **Step 1: Update `docs/core-api.md`**

Find the section that documents the `:http` effect (search for `redin.http` or `:http`). Add the `:timeout` field with its default and the new error shapes (status 0 with `error` containing the failure message; specifically: `"http timeout exceeded"`, `"too many concurrent http requests"`, `"http scheme must be http or https"`, `"host <name> not in http whitelist"`, `"http header contains invalid character"`).

Find the section that documents the `:shell` effect. Add `:timeout` (ms, default 30000) and `:max-output` (MiB, default 16). Document the failure shapes: `exit_code -1` with `error_msg` containing one of `"shell output exceeded N MiB cap"`, `"shell timeout exceeded N ms"`.

In the dev-server section, add a row noting that malformed `Content-Length` returns 400.

- [ ] **Step 2: Update `docs/reference/effects.md`**

Add the same fields with brief descriptions and the failure modes. Cross-reference `docs/reference/native-bridge.md` for the opt-in setters.

- [ ] **Step 3: Update `docs/reference/native-bridge.md`**

Append entries for `bridge.set_http_whitelist(allow: []string)` and `bridge.set_shell_env_allowlist(allow: []string)`. Include short examples:

```odin
// In app.odin
bridge.set_http_whitelist([]string{"api.example.com", "127.0.0.0/8"})
bridge.set_shell_env_allowlist([]string{"PATH", "HOME", "GITHUB_TOKEN"})
redin.run(cfg)
```

- [ ] **Step 4: Update `docs/reference/dev-server.md`**

Note the 400 response for malformed Content-Length, and that the dev server now aborts startup if `.redin-token` or `.redin-port` write fails (with a clear stderr line).

- [ ] **Step 5: Update `.claude/skills/redin-dev/SKILL.md`**

In the section that describes the effect maps, add the new optional fields. In the bridge-API section, add the two new setters.

- [ ] **Step 6: Skim `CLAUDE.md`**

Search for `redin.http` and `redin.shell` in `CLAUDE.md`. The current text in this file is broad (high-level conventions), so likely no update is needed. If you find a misleading example, fix it.

- [ ] **Step 7: Commit**

```bash
git add docs/core-api.md docs/reference/effects.md docs/reference/native-bridge.md docs/reference/dev-server.md .claude/skills/redin-dev/SKILL.md
git commit -m "$(cat <<'EOF'
docs: security audit fix surface (#99)

Documents the new effect-map fields (:timeout, :max-output) on
:http and :shell, the new public bridge setters
(set_http_whitelist, set_shell_env_allowlist), the failure
response shapes for the new reject paths (scheme, whitelist,
header CRLF, timeout, output cap, in-flight cap), the dev-server
400 on malformed Content-Length, and the now-fatal token-file
write failure. Same-commit docs landing per CLAUDE.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Final verification

No new code in this task. Run every gate from the `redin-maintenance` skill in order; fix anything that fails by going back to the relevant earlier task. Do not skip steps.

- [ ] **Step 1: Release build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: succeeds with no warnings. The dev-server code is excluded from this build (no `REDIN_DEV`), so L1/L2 changes contribute no symbols here.

- [ ] **Step 2: Dev build**

```bash
./build-dev.sh
```

Expected: succeeds.

- [ ] **Step 3: Agent build**

```bash
./build-dev.sh -define:REDIN_AGENT=true
```

Expected: succeeds. Confirms the agent path still compiles with the new bridge setters.

- [ ] **Step 4: Fennel runtime tests**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: 122 tests pass. The `:shell` and `:http` runtime paths now route extra params; if any existing test stubs `_G.redin_http` or `_G.redin_shell` with a fixed-arity proc, the test will fail with an arity error — fix the stub to accept (and ignore) the new params.

- [ ] **Step 5: Bridge unit tests**

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
```

If a race appears (it shouldn't, the bridge tests don't currently need it), retry with:

```bash
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

- [ ] **Step 6: UI integration tests**

```bash
bash test/ui/run-all.sh --headless
```

Expected: full suite passes. The hardening fixes are not UI-visible; this is the regression check.

- [ ] **Step 7: Tracking-allocator smoke**

```bash
./build/redin test/ui/smoke_app.fnl &
PID=$!
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
# Issue a few :http and :shell calls via the dev events endpoint, exercising
# success + cap + timeout paths. (Adapt to whatever events smoke_app.fnl
# defines; if none, write a one-off events sequence inline.)
sleep 2
curl -sf -X POST -H "Authorization: Bearer $TOKEN" \
  http://localhost:$PORT/shutdown
wait $PID
```

Inspect stderr for tracking-allocator leak lines. Expected: none. Pay special attention to the cloned allowlist slices (Tasks 6 and 7) and timed-out request cleanup (Task 8) — these are the new allocations introduced by this work.

- [ ] **Step 8: Final commit (if any in-task fixes were needed)**

If any previous task needed a touch-up (e.g. a leak or an unused import), commit those fixes with a clear message naming the task they patch up.

- [ ] **Step 9: Open the PR (optional, on user request)**

Not part of this plan — awaits the user's call.
