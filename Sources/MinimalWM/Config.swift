import Foundation

struct Config: Codable {
    var outerGap: CGFloat
    var innerGap: CGFloat
    var syncGaps: Bool
    var masterRatio: CGFloat
    var toggleKey: String
    var floatApps: [String]

    static let defaultConfig = Config(
        outerGap: 10,
        innerGap: 8,
        syncGaps: false,
        masterRatio: 0.55,
        toggleKey: "cmd+ctrl+space",
        floatApps: ["System Settings", "System Preferences", "Calculator", "Karabiner-Elements"]
    )

    private enum CodingKeys: String, CodingKey {
        case outerGap = "outer_gap"
        case innerGap = "inner_gap"
        case syncGaps = "sync_gaps"
        case masterRatio = "master_ratio"
        case toggleKey = "toggle_key"
        case floatApps = "float_apps"
    }

    init(
        outerGap: CGFloat,
        innerGap: CGFloat,
        syncGaps: Bool,
        masterRatio: CGFloat,
        toggleKey: String,
        floatApps: [String]
    ) {
        self.outerGap = outerGap
        self.innerGap = innerGap
        self.syncGaps = syncGaps
        self.masterRatio = masterRatio
        self.toggleKey = toggleKey
        self.floatApps = floatApps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outerGap = try values.decode(CGFloat.self, forKey: .outerGap)
        innerGap = try values.decode(CGFloat.self, forKey: .innerGap)
        syncGaps = try values.decodeIfPresent(Bool.self, forKey: .syncGaps) ?? false
        masterRatio = try values.decode(CGFloat.self, forKey: .masterRatio)
        toggleKey = try values.decode(String.self, forKey: .toggleKey)
        floatApps = try values.decode([String].self, forKey: .floatApps)
    }

    static func load() -> Config {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/minimalWM")
        let configFile = configDir.appendingPathComponent("config.json")

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
        return result
    }

    static func saveDefault() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/minimalWM")
        let configFile = configDir.appendingPathComponent("config.json")

        guard FileManager.default.fileExists(atPath: configDir.path) == false else { return }

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(defaultConfig)
            let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])
            try pretty.write(to: configFile)
            print("minimalWM: created default config at \(configFile.path)")
        } catch {
            print("minimalWM: failed to save default config: \(error)")
        }
    }

    func save() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/minimalWM")
        let configFile = configDir.appendingPathComponent("config.json")

        do {
            if !FileManager.default.fileExists(atPath: configDir.path) {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(self)
            let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])
            try pretty.write(to: configFile)
        } catch {
            print("minimalWM: failed to save config: \(error)")
        }
    }
}
