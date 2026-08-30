# Compiled QML provenance

Omarchy UI generated this package's native Qt module from the tree-shaken Zui and
Omarchy host QML graph. Generated QML source contents were discarded after AOT compilation.

- Format: `qt-aot-qml-module` version 1
- Qt: `6.11.2`
- Module: `OmarchyUI.Bundles.B6bd4bb02186cc0f33195`
- Source fingerprint: `6bd4bb02186cc0f331959068ee57064b507c70580e5cfa2d3e6996c26f72fffa`

## Artifacts

- `OmarchyUI/Bundles/B6bd4bb02186cc0f33195/libomarchy_ui_bundle_b6bd4bb02186cc0f33195.so` — `121b5c36cb8369c4a8a51912874d66325f5f57325df2b69881572cd05af34ce1`
- `OmarchyUI/Bundles/B6bd4bb02186cc0f33195/libomarchy_ui_bundle_b6bd4bb02186cc0f33195plugin.so` — `182e1cb9bfc924831d6ec32ba76c8ef566a26464fb8bd14360eddd7f833fe770`

Verify the packaged libraries from the plugin directory:

```bash
sha256sum --check omarchy-ui-qml-bundle.sha256
```

`App.qml`, `Service.qml`, `Panel.qml`, and `BarWidget.qml` are the minimal loader shims
required by Omarchy's file-based entry-point contract. Application UI lives in the compiled
module recorded by `omarchy-ui-qml-bundle.json`.
