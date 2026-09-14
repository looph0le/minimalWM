import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var wm = WindowManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            toggle

            if wm.isEnabled {
                Divider()
                layoutControls
                Divider()
                hotkeyHelp
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x2")
                .font(.title3)
                .foregroundStyle(wm.isEnabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("minimalWM")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text(wm.isEnabled ? "Tiling is active" : "Tiling is paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(wm.isEnabled ? Color.green : Color.gray)
                .frame(width: 9, height: 9)
        }
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Layout")
            masterSlider
            gapControls
        }
    }

    private var gapControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gaps")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(wm.isGapsSynced ? "Synced" : "Independent")
                    .font(.caption2)
                    .foregroundStyle(wm.isGapsSynced ? Color.accentColor : Color.secondary)
            }
            outerGapSlider
            innerGapSlider
            Toggle("Keep outer and inner equal", isOn: Binding(
                get: { wm.isGapsSynced },
                set: { wm.setGapsSynced($0) }
            ))
            .toggleStyle(.switch)
            .font(.caption)
            Text("Editing either gap turns sync off.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var toggle: some View {
        Button {
            wm.toggle()
        } label: {
            HStack {
                Text(wm.isEnabled ? "Disable Tiling" : "Enable Tiling")
                Spacer()
                Text("⌘⌃ Space")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
    }

    private var masterSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            controlLabel("Master Width", value: "\(Int(wm.masterRatio * 100))%")
            Slider(value: Binding(
                get: { wm.masterRatio },
                set: { wm.setMasterRatio($0) }
            ), in: 0.25...0.75, step: 0.01,
            onEditingChanged: { editing in
                if !editing { wm.commitConfig() }
            })
        }
    }

    private var outerGapSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            controlLabel("Outer Gap", value: "\(Int(wm.outerGap)) px")
            Slider(value: Binding(
                get: { wm.outerGap },
                set: { wm.setOuterGap($0) }
            ), in: 0...40, step: 1,
            onEditingChanged: { editing in
                if !editing { wm.commitConfig() }
            })
        }
    }

    private var innerGapSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            controlLabel("Inner Gap", value: "\(Int(wm.innerGap)) px")
            Slider(value: Binding(
                get: { wm.innerGap },
                set: { wm.setInnerGap($0) }
            ), in: 0...40, step: 1,
            onEditingChanged: { editing in
                if !editing { wm.commitConfig() }
            })
        }
    }

    private var hotkeyHelp: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle("Shortcuts")
            hotkey("⌘⌃ H / L", "focus left / right")
            hotkey("⌘⌃⇧ H / L", "swap left / right")
            hotkey("⌘⌃ J / K", "shrink / grow master")
            hotkey("⌘⌃ F", "toggle float")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.7)
    }

    private func controlLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func hotkey(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key).font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text(desc).font(.caption2)
        }
    }
}