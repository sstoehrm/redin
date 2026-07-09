# Vendored LuaJIT

`lib/libluajit-5.1.a` is a prebuilt static archive of the LuaJIT C library,
statically linked into every redin binary (see `foreign import luajit` in
`src/redin/bridge/lua_api.odin`). It is **not** built from source in this
repo, so its provenance is recorded here and its hash is asserted in CI.

| Field | Value |
|-------|-------|
| Upstream | https://github.com/LuaJIT/LuaJIT |
| Branch | `v2.1` (rolling release) |
| Version string | `LuaJIT 2.1.1703358377` |
| Upstream commit | the `v2.1` commit whose committer timestamp is `1703358377` (2023-12-23 19:06 UTC) — LuaJIT's rolling version is `2.1.<committer-unix-timestamp>` |
| Lua API level | 5.1 (LuaJIT implements the Lua 5.1 API + extensions) |
| License | MIT (Copyright © 2005–2023 Mike Pall) |
| File | `lib/libluajit-5.1.a` |
| sha256 | `815b62f89420861c76b6ddd48b9efcff93248c10df4688cda18f85cac9e45f3b` |

The version string can be recovered from the archive itself:

```bash
strings vendor/luajit/lib/libluajit-5.1.a | grep -m1 'LuaJIT 2'
```

## Updating

Rebuild from the desired upstream commit and replace the archive:

```bash
git clone https://github.com/LuaJIT/LuaJIT
cd LuaJIT && git checkout <commit> && make
# produces src/libluajit.a → copy to vendor/luajit/lib/libluajit-5.1.a
```

Then update **both** the `Version string` / `sha256` above **and** the
expected hash in `.github/workflows/test.yml` (the "Verify vendored blob
hashes" step) in the same commit, so an unreviewed swap of this binary blob
can't pass CI. See #233 M3.
