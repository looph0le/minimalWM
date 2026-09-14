# minimalWM

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A minimal tiling window manager for macOS with configurable gaps.

Automatically arranges windows in a master-stack layout with inner and outer gaps. Runs as a menu bar app — one click to toggle, zero config to start.

## Install

```bash
git clone https://github.com/looph0le/minimalWM.git
cd minimalWM
swift build -c release
./install.sh
```

## Run

```bash
minimalWM
```

On first launch, you will be prompted to grant **Accessibility** permission in *System Settings → Privacy & Security → Accessibility*.

The app controls other applications through macOS Accessibility APIs. It runs locally and does not require an account, network service, or remote backend.

## Layout

```
┌──────────────────┬──────────┐
│                  │          │
│     MASTER       │  STACK   │
│  (code editor)   │ (term,   │
│                  │  docs)   │
│                  │          │
│                  ├──────────┤
│                  │  STACK   │
│                  │ (browser)│
└──────────────────┴──────────┘
```

- One master window on the left (~55% width, configurable)
- Remaining windows split the right column equally
- Gaps between all windows and around screen edges

## Hotkeys

| Key | Action |
|-----|--------|
| `⌘⌃ Space` | Toggle tiling on/off |
| `⌘⌃ H / L` | Focus left / right |
| `⌘⌃⇧ H / L` | Swap window left / right |
| `⌘⌃ J / K` | Shrink / grow master area |
| `⌘⌃ F` | Toggle float on focused window |

## Configuration

Config file: `~/.config/minimalWM/config.json`

```json
{
  "outer_gap": 10,
  "inner_gap": 8,
  "sync_gaps": false,
  "master_ratio": 0.55,
  "toggle_key": "cmd+ctrl+space",
  "float_apps": [
    "System Settings",
    "Calculator"
  ]
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `outer_gap` | `10` | Space between windows and screen edges (px) |
| `inner_gap` | `8` | Space between adjacent windows (px) |
| `sync_gaps` | `false` | Keep outer and inner gaps equal; editing either gap disables sync |
| `master_ratio` | `0.55` | Master window width as fraction of available space (0.25–0.75) |
| `float_apps` | `[]` | App names to exclude from tiling |

Changes are applied immediately when saved.

## Menu Bar

Click the tiling icon in your menu bar to:
- Toggle tiling on/off
- Adjust master width, outer gap, and inner gap with sliders
- See hotkey reference
- Quit

## How It Works

- Uses the macOS Accessibility API (AXUIElement) to read and set window positions
- Observes window events (create, move, resize, close) via AXObserver to re-tile automatically
- Polls Accessibility window topology twice per second as a fallback for missed events
- Respects macOS native workspaces — tiles per-display, per-space
- Handles Chromium/Electron apps via the AXEnhancedUserInterface workaround
- Drag previews use directional slot boundaries with a small hysteresis band to avoid order flicker
- The dragged window is left under user control until release; empty-space drops restore the prior order

### Development

```bash
./dev.sh --once
```

`dev.sh` optionally uses a local codesigning identity named `MinimalWM Developer` to preserve Accessibility trust across rebuilds. This identity is not included with the project and is not required for release builds.

## Contributing

Issues and pull requests are welcome. Please include the macOS version, hardware architecture, Swift version, and relevant debug output when reporting a problem. Never include credentials, private keys, or personal configuration files in an issue or pull request.

## Requirements

- macOS 14.0+
- Swift 6.0+

## License

MIT
