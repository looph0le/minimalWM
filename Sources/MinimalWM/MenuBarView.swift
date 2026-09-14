import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var wm = WindowManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            toggle

            if !wm.accessibilityGranted {
                Divider()
                accessibilityOnboarding
            } else if wm.isEnabled {
                Divider()
                layoutControls
                Divider()
                floatingSection
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
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: wm.isEnabled ? "rectangle.split.2x2.fill" : "rectangle.split.2x2")
                .font(.title3)
                .foregroundStyle(wm.isEnabled ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("minimalWM")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
        }
    }

    private var statusText: String {
        if !wm.accessibilityGranted {
            return "Accessibility permission needed"
        }
        return wm.isEnabled ? "Tiling is active" : "Tiling is paused"
    }

    private var statusColor: Color {
        if !wm.accessibilityGranted {
            return Color.orange
        }
        return wm.isEnabled ? Color.green : Color.gray
    }

    private var accessibilityOnboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Accessibility Permission")
            Text("minimalWM reads and arranges other apps' windows, which macOS only allows with Accessibility access.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openAccessibilitySettings()
            } label: {
                Label("Open System Settings", systemImage: "cursorarrow.click.2")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                wm.refreshAccessibilityStatus()
            } label: {
                Text("Check Again")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            Text("Grant permission for minimalWM, then click Check Again — no restart needed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Layout")
            masterSlider
            gapControls
            newWindowToggle
        }
    }

    private var newWindowToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("New window becomes master", isOn: Binding(
                get: { wm.newWindowAsMaster },
                set: { wm.setNewWindowAsMaster($0) }
            ))
            .toggleStyle(.switch)
            .font(.caption)
            Text(wm.newWindowAsMaster
                 ? "New windows take the master slot; existing windows cycle down."
                 : "New windows join the end of the stack; positions stay put.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                if let toggleHotkey = wm.hotkeys.first(where: { $0.action == .toggleTiling }) {
                    Text(toggleHotkey.display)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var floatingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Floating Windows")
                Spacer()
                if !wm.floatingList.isEmpty {
                    Button("Clear All") { wm.unfloatAll() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            if wm.floatingList.isEmpty {
                Text("Press \(floatKeyHint) to float the focused window.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(wm.floatingList) { info in
                    HStack(spacing: 6) {
                        Image(systemName: "pin.slash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.title)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(info.app)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unfloat") { wm.unfloat(info.element) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("Floats are remembered across restarts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var floatKeyHint: String {
        wm.hotkeys.first(where: { $0.action == .toggleFloat })?.display ?? "⌘⌃ F"
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
            ForEach(Array(wm.hotkeys.enumerated()), id: \.offset) { _, hk in
                hotkey(hk.display, hk.name)
            }
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