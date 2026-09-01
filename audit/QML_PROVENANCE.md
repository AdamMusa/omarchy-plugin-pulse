# Compiled QML provenance

Omarchy UI generated this package's native Qt module from the tree-shaken Zui and
Omarchy host QML graph. The exact generated source graph and CMake build definition are
retained in `audit/qml-source/` for independent audit and byte-for-byte reproduction.

- Format: `qt-aot-qml-module` version 1
- Qt: `6.11.2`
- Module: `OmarchyUI.Bundles.Bba59c6b96f4f5700ef46`
- Source fingerprint: `ba59c6b96f4f5700ef465691c5d960b50ec7e1cc173d4e03dd2f5bf0b7132f34`

## Artifacts

- `OmarchyUI/Bundles/Bba59c6b96f4f5700ef46/libomarchy_ui_bundle_bba59c6b96f4f5700ef46.so` — `18e68215312d557ae697dcca3c0f627c80c13bae82c21b993c169c42bbfb538e`
- `OmarchyUI/Bundles/Bba59c6b96f4f5700ef46/libomarchy_ui_bundle_bba59c6b96f4f5700ef46plugin.so` — `01993c7267416bd735d08b204218e7e5854cc1aa422291fbe066e560a6013be0`

Verify the packaged libraries from the plugin directory:

```bash
sha256sum --check audit/omarchy-ui-qml-bundle.sha256
```

Rebuild the checked-in libraries from the retained sources and compare every byte:

```bash
audit/rebuild-qml-bundle.sh
```

The pinned toolchain, CI process, and GitHub artifact-attestation flow are documented in
[`REPRODUCIBLE_BUILD.md`](REPRODUCIBLE_BUILD.md).

`Service.qml`, `Panel.qml`, and `BarWidget.qml` are the minimal loader shims required for the
plugin kinds declared in `manifest.json`. Application UI lives in the compiled
module recorded by `audit/omarchy-ui-qml-bundle.json`.
