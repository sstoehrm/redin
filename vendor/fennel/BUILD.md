# Vendored Fennel

`fennel.lua` is the single-file Fennel compiler, byte-shipped in every redin
release tarball and loaded at startup (see `load_fennel` in
`src/redin/bridge/bridge.odin`). It is copied verbatim from an upstream
release, so its provenance is recorded here and its hash is asserted in CI.

| Field | Value |
|-------|-------|
| Upstream | https://fennel-lang.org / https://git.sr.ht/~technomancy/fennel |
| Version | `1.5.1` (see `version = "1.5.1"` in `fennel.lua`) |
| License | MIT |
| File | `fennel.lua` |
| sha256 | `420b3e4771be263066c220aa042f02457ce5848e493ddf463cff4eca76ef9ba1` |

The version can be recovered from the file itself:

```bash
grep -m1 'version = "' vendor/fennel/fennel.lua
```

## Updating

Download the single-file build for the desired release and replace the file:

```bash
curl -fsSLo vendor/fennel/fennel.lua https://fennel-lang.org/downloads/fennel-<version>
```

Then update **both** the `Version` / `sha256` above **and** the expected hash
in `.github/workflows/test.yml` (the "Verify vendored blob hashes" step) in
the same commit, so an unreviewed replacement of this shipped file can't pass
CI. See #233 M3.
