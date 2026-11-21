import Foundation
import CryptoKit
import Darwin

struct MinecraftVersion: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let url: URL
    let sha1: String
    let releaseTime: String
}

struct VersionManifest: Decodable {
    struct Latest: Decodable { let release: String }
    let latest: Latest
    let versions: [MinecraftVersion]

    var supportedReleases: [MinecraftVersion] {
        versions.filter { $0.type == "release" && $0.releaseTime >= "2021-11-30" }
    }
}

struct VersionDetails: Decodable {
    struct JavaVersion: Decodable { let majorVersion: Int }
    struct Download: Decodable {
        let url: URL
        let sha1: String
        let size: Int
    }
    struct Downloads: Decodable { let server: Download? }
    let javaVersion: JavaVersion
    let downloads: Downloads
}

struct ServerSettings: Codable {
    var profileOptions: [String:[String:String]]?
    var displayName: String?
    var version = ""
    var memoryGB = 2
    var port = "25565"
    var maxPlayers = 8
    var gameMode = "survival"
    var difficulty = "normal"
    var viewDistance: Int?
    var simulationDistance: Int?
    var allowUnverified: Bool?
    var acceptedEULA = false
}

struct LanternError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct ServerPaths {
    let root: URL
    let sharedRoot: URL?
    var settings: URL { root.appendingPathComponent("settings.json") }
    var manifest: URL { (sharedRoot ?? root).appendingPathComponent("versions.json") }
    var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    var runtimes: URL { (sharedRoot ?? root).appendingPathComponent("Java", isDirectory: true) }

    init(root: URL? = nil, sharedRoot: URL? = nil) {
        self.sharedRoot = sharedRoot
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lantern Minecraft", isDirectory: true)
    }

    func profile(_ version: String) -> URL {
        root.appendingPathComponent("Servers", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    func createDirectories() throws {
        for directory in [root, backups, runtimes] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

enum ServerFiles {
    static func digest(_ file: URL, sha256: Bool = false) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha1Hasher = Insecure.SHA1()
        var sha256Hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            if sha256 { sha256Hasher.update(data: data) }
            else { sha1Hasher.update(data: data) }
        }
        let bytes: [UInt8] = sha256 ? Array(sha256Hasher.finalize()) : Array(sha1Hasher.finalize())
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func writeProperties(at file: URL, settings: ServerSettings) throws {
        var updates = [
            "server-port": settings.port,
            "max-players": String(settings.maxPlayers),
            "gamemode": settings.gameMode,
            "difficulty": settings.difficulty
        ]
        for key in ["level-name","level-seed","level-type","motd","resource-pack","resource-pack-sha1","require-resource-pack","entity-broadcast-range-percentage","white-list","allow-flight","player-idle-timeout","hardcore","spawn-protection"] {
            if let value=settings.options[key] { updates[key]=value }
        }
        if let value=settings.options["rule.pvp"] { updates["pvp"]=value }
        if let value=settings.options["rule.command_blocks_work"] { updates["enable-command-block"]=value }
        for (key,value) in updates where value.contains(where: { $0.isNewline }) || value.contains("\\") {
            throw LanternError("Remove line breaks and backslashes from "+key+".")
        }
        if let name=updates["level-name"], name.isEmpty || name == "." || name == ".." || name.contains("/") { throw LanternError("Choose a simple world folder name.") }
        if let view = settings.viewDistance { updates["view-distance"] = String(view) }
        if let sim = settings.simulationDistance { updates["simulation-distance"] = String(sim) }
        if let allow = settings.allowUnverified {
            updates["online-mode"] = String(!allow)
            updates["enforce-secure-profile"] = String(!allow)
        }
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: .newlines)
        var remaining = updates
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.hasPrefix("!"),
                  let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            if let value = updates[key] {
                lines[index] = "\(key)=\(value)"
                remaining.removeValue(forKey: key)
            }
        }
        for key in remaining.keys.sorted() { lines.append("\(key)=\(remaining[key]!)") }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func localAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var addresses: [(String, String)] = []
        var pointer = interfaces
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses.append((name, String(cString: host)))
        }
        return addresses.sorted { $0.0 < $1.0 }.first?.1
    }

    static func portIsAvailable(_ port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func backup(profile: URL, destination: URL, version: String) async throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: profile.appendingPathComponent("server.properties").path) else {
            throw LanternError("Start this version once to create a world before making a backup.")
        }
        let staging = destination.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        // Include every custom world directory, along with permissions and server settings.
        for item in try manager.contentsOfDirectory(at: profile, includingPropertiesForKeys: [.isDirectoryKey]) {
            let isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if (isDirectory && !["libraries", "versions", "logs", "crash-reports"].contains(item.lastPathComponent))
                || item.pathExtension == "json" || ["server.properties", "server-icon.png"].contains(item.lastPathComponent) {
                try manager.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
            }
        }
        try Data("Minecraft Java Edition \(version)\n".utf8).write(to: staging.appendingPathComponent("Minecraft version.txt"))
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archive = destination.appendingPathComponent("Minecraft-\(version)-\(stamp)-\(UUID().uuidString.prefix(4)).zip")
        let partial = archive.appendingPathExtension("partial")
        defer { try? manager.removeItem(at: partial) }
        _ = try await Command.run("/usr/bin/ditto", ["-c", "-k", staging.path, partial.path])
        try manager.moveItem(at: partial, to: archive)
        return archive
    }
}

enum Command {
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) async throws -> String {
        let process = Process()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: output, as: UTF8.self)
                guard process.terminationStatus == 0 else {
                    throw LanternError(text.isEmpty ? "A setup tool could not finish." : text)
                }
                return text
            }.value
        }, onCancel: {
            if process.isRunning { process.terminate() }
        })
    }
}
