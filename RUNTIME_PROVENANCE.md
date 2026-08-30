# Omarchy UI runtime provenance

The bundled `omarchy-ui-runtime` is byte-for-byte the artifact published by an
independently attested Omarchy UI release. It is verified separately from the
earlier runtime bundled by the marketplace-approved Omarchy Phone plugin.

- Release: [`runtime-v0.1.1`](https://github.com/AdamMusa/omarchy-ui/releases/tag/runtime-v0.1.1)
- Runtime source revision: [`eec479d6974db46dcc6fc4246219e5e326be8e92`](https://github.com/AdamMusa/omarchy-ui/tree/eec479d6974db46dcc6fc4246219e5e326be8e92)
- Adapter release: [`omarchy-ui` `0.0.5`](https://rubygems.org/gems/omarchy-ui/versions/0.0.5) (`zui ~> 0.0.10`)
- Adapter gem SHA-256: `2d392c71b6f626908501b29d3cb5d49b77ddffa36c68cbf97f4e8b8663030e2c`
- Zui release: [`zui` `0.0.10`](https://rubygems.org/gems/zui/versions/0.0.10)
- Zui gem SHA-256: `ceec71d836c396b9944c85d5f472d34f14596a28a6dbf0c0b4687a01031627c0`
- Remote build: [GitHub Actions run `33294299488`](https://github.com/AdamMusa/omarchy-ui/actions/runs/33294299488)
- Signed provenance: [GitHub artifact attestation `43924917`](https://github.com/AdamMusa/omarchy-ui/attestations/43924917)
- SHA-256: `ccf010017a5f6d2ae06def4357e6bce2b344e6f245f195c5dbee92cd048017b0`
- Size: `1,868,040` bytes
- Target: x86-64 Linux

Verify independently:

```bash
sha256sum --check omarchy-ui-runtime.sha256
gh attestation verify omarchy-ui-runtime --repo AdamMusa/omarchy-ui

verify_dir=$(mktemp -d)
gh release download runtime-v0.1.1 --repo AdamMusa/omarchy-ui   --pattern omarchy-ui-runtime --dir "$verify_dir"
cmp omarchy-ui-runtime "$verify_dir/omarchy-ui-runtime"
```

The release workflow pins all external source revisions, performs two clean builds,
requires byte-identical output, and signs the resulting artifact through GitHub attestations.
