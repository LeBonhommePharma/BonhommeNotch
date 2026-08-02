import Foundation

public enum BonhommePaths {
    public static let appSupportName = "BonhommeNotch"
    public static let socketFileName = "notch.sock"
    public static let statusFileName = "status.json"

    /// Override with BONHOMME_NOTCH_SOCKET or AGENT_NOTCH_SOCKET (compat).
    public static func socketPath(fileManager: FileManager = .default) -> String {
        if let env = ProcessInfo.processInfo.environment["BONHOMME_NOTCH_SOCKET"], !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["AGENT_NOTCH_SOCKET"], !env.isEmpty {
            return env
        }
        return (applicationSupportDirectory(fileManager: fileManager) as NSString)
            .appendingPathComponent(socketFileName)
    }

    public static func applicationSupportDirectory(fileManager: FileManager = .default) -> String {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(appSupportName, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    public static func statusPath(fileManager: FileManager = .default) -> String {
        (applicationSupportDirectory(fileManager: fileManager) as NSString)
            .appendingPathComponent(statusFileName)
    }
}
