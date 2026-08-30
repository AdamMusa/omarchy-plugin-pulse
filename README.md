# Plugin Pulse

[![Omarchy UI](https://img.shields.io/badge/built_with-Omarchy_UI-9bff73)](https://github.com/AdamMusa/omarchy-ui)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**See which plugins are actually loaded, what they launch, and where the shell is struggling.**

Plugin Pulse builds a local runtime map from Omarchy's plugin registry, the live process table, recent user journal entries, installed source trees, and Git metadata. It shows dedicated runtimes, shared-shell plugins, executable payloads, command and network cues, reload activity, and attributable errors without executing inspected plugin code.

![Plugin Pulse preview](preview.png)

## Why this is distinct

Existing security scanners classify plugin source or gate updates. Plugin Pulse is an operations view: it correlates the currently enabled registry with live processes and recent shell behavior. It reports evidence and anomalies, never a malware-free verdict.

The concept was checked against the complete Omarchy Plugin Marketplace catalog before development.

## Install

```bash
omarchy plugin add https://github.com/AdamMusa/omarchy-plugin-pulse.git --enable
```

Review third-party plugin code before enabling it. Omarchy community plugins run with your user account.

## Use

Add **Plugin Pulse** to the Omarchy bar and click its widget to open the panel. The plugin is keyboard-friendly, theme-aware, and designed for a 660 × 760 panel.

## Data, permissions, and safety

- Local state: `~/.local/state/omarchy-plugin-pulse/state.json`
- State, command output, item counts, history, and rendered strings are bounded.
- State writes use an owner-only temporary file and atomic rename.
- System probes are read-only and invoke fixed argument arrays without a shell.
- No telemetry, analytics, remote account, package installation, or privileged command is used.
- The plugin never overwrites Omarchy, Hyprland, or application configuration.

External runtime tools are limited to standard commands already present on Omarchy when a feature needs them. Missing optional commands degrade to an explicit unavailable state. The exact commands are visible in [`lib/backend.rb`](lib/backend.rb).

## Remove

```bash
omarchy plugin remove izeesoft.plugin-pulse
```

Removal leaves the local state file in place so reinstalling preserves history. To erase it too:

```bash
rm -r ~/.local/state/omarchy-plugin-pulse
```

## Marketplace metadata

- Plugin ID: `izeesoft.plugin-pulse`
- Category: Developer Tools
- Tags: quickshell, system, bar
- Kinds: service, bar widget, panel
- Target: Omarchy Quattro on x86-64 Linux

## Development

The user interface is written entirely in Ruby with [Omarchy UI](https://github.com/AdamMusa/omarchy-ui). Generated QML bridge files and the attested mruby runtime are distribution artifacts.

```bash
sha256sum --check omarchy-ui-runtime.sha256
ruby test/backend_test.rb
omarchy plugin validate .
```

Runtime provenance and independent verification steps are documented in [`RUNTIME_PROVENANCE.md`](RUNTIME_PROVENANCE.md).

## License

MIT.
