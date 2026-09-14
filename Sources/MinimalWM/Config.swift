import Foundation

struct FloatingWindowDescriptor: Codable, Equatable {
    var app: String
    var title: String
}

struct Config: Codable {
    var outerGap: CGFloat
    var innerGap: CGFloat
    var syncGaps: Bool
    var masterRatio: CGFloat
    var toggleKey: String
    var floatApps: [String]
    var floatingWindows: [FloatingWindowDescriptor]
    var focusLeftKey: String
    var focusRightKey: String
    var swapLeftKey: String
    var swapRightKey: String
    var growMasterKey: String
    var shrinkMasterKey: String
    var toggleFloatKey: String
    var newWindowPosition: String

    static let defaultConfig = Config(
        outerGap: 10,
        innerGap: 8,
        syncGaps: false,
        masterRatio: 0.55,
        toggleKey: "cmd+ctrl+space",
        floatApps: ["System Settings", "System Preferences", "Calculator", "Karabiner-Elements"],
        floatingWindows: [],
        focusLeftKey: "cmd+ctrl+h",
        focusRightKey: "cmd+ctrl+l",
        swapLeftKey: "cmd+ctrl+shift+h",
        swapRightKey: "cmd+ctrl+shift+l",
        growMasterKey: "cmd+ctrl+k",
        shrinkMasterKey: "cmd+ctrl+j",
        toggleFloatKey: "cmd+ctrl+f",
        newWindowPosition: "master"
    )

    private enum CodingKeys: String, CodingKey {
        case outerGap = "outer_gap"
        case innerGap = "inner_gap"
        case syncGaps = "sync_gaps"
        case masterRatio = "master_ratio"
        case toggleKey = "toggle_key"
        case floatApps = "float_apps"
        case floatingWindows = "floating_windows"
        case focusLeftKey = "focus_left_key"
        case focusRightKey = "focus_right_key"
        case swapLeftKey = "swap_left_key"
        case swapRightKey = "swap_right_key"
        case growMasterKey = "grow_master_key"
        case shrinkMasterKey = "shrink_master_key"
        case toggleFloatKey = "float_key"
        case newWindowPosition = "new_window_position"
    }

    init(
        outerGap: CGFloat,
        innerGap: CGFloat,
        syncGaps: Bool,
        masterRatio: CGFloat,
        toggleKey: String,
        floatApps: [String],
        floatingWindows: [FloatingWindowDescriptor],
        focusLeftKey: String,
        focusRightKey: String,
        swapLeftKey: String,
        swapRightKey: String,
        growMasterKey: String,
        shrinkMasterKey: String,
        toggleFloatKey: String,
        newWindowPosition: String
    ) {
        self.outerGap = outerGap
        self.innerGap = innerGap
        self.syncGaps = syncGaps
        self.masterRatio = masterRatio
        self.toggleKey = toggleKey
        self.floatApps = floatApps
        self.floatingWindows = floatingWindows
        self.focusLeftKey = focusLeftKey
        self.focusRightKey = focusRightKey
        self.swapLeftKey = swapLeftKey
        self.swapRightKey = swapRightKey
        self.growMasterKey = growMasterKey
        self.shrinkMasterKey = shrinkMasterKey
        self.toggleFloatKey = toggleFloatKey
        self.newWindowPosition = newWindowPosition
    }

    init(from decoder: Decoder) throws {
        let d = Config.defaultConfig
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outerGap = try values.decodeIfPresent(CGFloat.self, forKey: .outerGap) ?? d.outerGap
        innerGap = try values.decodeIfPresent(CGFloat.self, forKey: .innerGap) ?? d.innerGap
        syncGaps = try values.decodeIfPresent(Bool.self, forKey: .syncGaps) ?? d.syncGaps
        masterRatio = try values.decodeIfPresent(CGFloat.self, forKey: .masterRatio) ?? d.masterRatio
        toggleKey = try values.decodeIfPresent(String.self, forKey: .toggleKey) ?? d.toggleKey
        floatApps = try values.decodeIfPresent([String].self, forKey: .floatApps) ?? d.floatApps
        floatingWindows = try values.decodeIfPresent([FloatingWindowDescriptor].self, forKey: .floatingWindows) ?? d.floatingWindows
        focusLeftKey = try values.decodeIfPresent(String.self, forKey: .focusLeftKey) ?? d.focusLeftKey
        focusRightKey = try values.decodeIfPresent(String.self, forKey: .focusRightKey) ?? d.focusRightKey
        swapLeftKey = try values.decodeIfPresent(String.self, forKey: .swapLeftKey) ?? d.swapLeftKey
        swapRightKey = try values.decodeIfPresent(String.self, forKey: .swapRightKey) ?? d.swapRightKey
        growMasterKey = try values.decodeIfPresent(String.self, forKey: .growMasterKey) ?? d.growMasterKey
        shrinkMasterKey = try values.decodeIfPresent(String.self, forKey: .shrinkMasterKey) ?? d.shrinkMasterKey
        toggleFloatKey = try values.decodeIfPresent(String.self, forKey: .toggleFloatKey) ?? d.toggleFloatKey
        newWindowPosition = try values.decodeIfPresent(String.self, forKey: .newWindowPosition) ?? d.newWindowPosition
    }

    static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/minimalWM")
    }

    static var configFileURL: URL {
        configDirectoryURL.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        let configFile = configFileURL

        guard FileManager.default.fileExists(atPath: configFile.path) else {
            saveDefault()
            return defaultConfig
        }

        do {
            let data = try Data(contentsOf: configFile)
            return try JSONDecoder().decode(Config.self, from: data).validated()
        } catch {
            print("minimalWM: failed to parse config, using defaults: \(error)")
            return defaultConfig
        }
    }

    func validated() -> Config {
        var result = self
        result.outerGap = max(0, min(200, outerGap))
        result.innerGap = max(0, min(200, innerGap))
        result.syncGaps = syncGaps
        result.masterRatio = max(0.2, min(0.8, masterRatio))
        result.toggleKey = toggleKey.isEmpty ? Self.defaultConfig.toggleKey : toggleKey
        result.focusLeftKey = focusLeftKey.isEmpty ? Self.defaultConfig.focusLeftKey : focusLeftKey
        result.focusRightKey = focusRightKey.isEmpty ? Self.defaultConfig.focusRightKey : focusRightKey
        result.swapLeftKey = swapLeftKey.isEmpty ? Self.defaultConfig.swapLeftKey : swapLeftKey
        result.swapRightKey = swapRightKey.isEmpty ? Self.defaultConfig.swapRightKey : swapRightKey
        result.growMasterKey = growMasterKey.isEmpty ? Self.defaultConfig.growMasterKey : growMasterKey
        result.shrinkMasterKey = shrinkMasterKey.isEmpty ? Self.defaultConfig.shrinkMasterKey : shrinkMasterKey
        result.toggleFloatKey = toggleFloatKey.isEmpty ? Self.defaultConfig.toggleFloatKey : toggleFloatKey
        if newWindowPosition != "master" && newWindowPosition != "stack" {
            result.newWindowPosition = Self.defaultConfig.newWindowPosition
        }
        return result
    }

    static func saveDefault() {
        let configFile = configFileURL

        guard FileManager.default.fileExists(atPath: configDirectoryURL.path) == false else { return }

        do {
            try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(defaultConfig)
            let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])
            try pretty.write(to: configFile)
            print("minimalWM: created default config at \(configFile.path)")
        } catch {
            print("minimalWM: failed to save default config: \(error)")
        }
    }

    func save() {
        let configFile = Config.configFileURL

        do {
            if !FileManager.default.fileExists(atPath: Config.configDirectoryURL.path) {
                try FileManager.default.createDirectory(at: Config.configDirectoryURL, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(self)
            let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])
            try pretty.write(to: configFile)
        } catch {
            print("minimalWM: failed to save config: \(error)")
        }
    }
}

// Reloads the config whenever ~/.config/minimalWM/config.json changes on disk,
// giving the documented "changes apply when saved" behavior.
final class ConfigWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    func start() {
        guard source == nil else { return }
        let fd = open(Config.configFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .attrib, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
    }

    private func scheduleReload() {
        debounce?.cancel()
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                WindowManager.shared.loadConfig()
            }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}