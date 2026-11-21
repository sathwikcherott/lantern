import Foundation

actor Downloads {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration)
    }()

    func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return data
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LanternError("The download service could not respond. Check your internet connection and try again.")
        }
    }

    func manifest(at cache: URL) async throws -> VersionManifest {
        do {
            let bytes = try await data(from: URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!)
            let result = try JSONDecoder().decode(VersionManifest.self, from: bytes)
            try bytes.write(to: cache, options: .atomic)
            return result
        } catch {
            if let cached = try? Data(contentsOf: cache),
               let manifest = try? JSONDecoder().decode(VersionManifest.self, from: cached) { return manifest }
            throw error
        }
    }

    func details(for version: MinecraftVersion, profile: URL) async throws -> VersionDetails {
        let cache = profile.appendingPathComponent("version.json")
        if let existing = try? Data(contentsOf: cache),
           let details = try? JSONDecoder().decode(VersionDetails.self, from: existing),
           try ServerFiles.digest(cache) == version.sha1 { return details }
        let bytes = try await data(from: version.url)
        let temporary = profile.appendingPathComponent(".version-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary)
        guard try ServerFiles.digest(temporary) == version.sha1 else {
            throw LanternError("Minecraft’s version information failed verification. Please retry.")
        }
        let result = try JSONDecoder().decode(VersionDetails.self, from: bytes)
        try bytes.write(to: cache, options: .atomic)
        return result
    }

    func server(_ download: VersionDetails.Download, in profile: URL) async throws -> URL {
        let target = profile.appendingPathComponent("server.jar")
        if FileManager.default.fileExists(atPath: target.path),
           try ServerFiles.digest(target) == download.sha1 { return target }
        let (temporary, response) = try await session.download(from: download.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validate(response)
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.intValue == download.size,
              try ServerFiles.digest(temporary) == download.sha1 else {
            throw LanternError("The server download failed verification. Please retry.")
        }
        _ = try FileManager.default.replaceOrMove(temporary, to: target)
        return target
    }

    private var preparingJava: [URL: Task<URL, Error>] = [:]

    func java(major: Int, in runtimes: URL) async throws -> URL {
        let key = runtimes.appendingPathComponent(String(major))
        if let pending = preparingJava[key] { return try await pending.value }
        let pending = Task { try await self.prepareJava(major: major, in: runtimes) }
        preparingJava[key] = pending
        defer { preparingJava[key] = nil }
        return try await pending.value
    }

    private func prepareJava(major: Int, in runtimes: URL) async throws -> URL {
        guard [17, 21, 25].contains(major) else {
            throw LanternError("This Minecraft version needs Java \(major). Lantern currently supports Java 17, 21 and 25.")
        }
        // Prefer an existing matching installation before fetching a private runtime.
        if let home = try? await Command.run("/usr/libexec/java_home", ["-v", String(major)]) {
            let executable = URL(fileURLWithPath: home.trimmingCharacters(in: .whitespacesAndNewlines))
                .appendingPathComponent("bin/java")
            if await matchesJava(executable, major: major) { return executable }
        }
        let target = runtimes.appendingPathComponent(String(major), isDirectory: true)
        if let executable = javaExecutable(in: target), await matchesJava(executable, major: major) {
            return executable
        }
        #if arch(arm64)
        let architecture = "aarch64"
        #else
        let architecture = "x64"
        #endif
        let downloadURL = URL(string: "https://aka.ms/download-jdk/microsoft-jdk-\(major)-macOS-\(architecture).tar.gz")!
        let checksumURL = URL(string: downloadURL.absoluteString + ".sha256sum.txt")!
        let expected = String(decoding: try await data(from: checksumURL), as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard expected.count == 64 else { throw LanternError("Java’s download checksum could not be read.") }
        let (archive, response) = try await session.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: archive) }
        try validate(response)
        guard try ServerFiles.digest(archive, sha256: true) == expected.lowercased() else {
            throw LanternError("The Java download failed verification. Please retry.")
        }
        let staging = runtimes.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try await Command.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        try Task.checkCancellation()
        guard let stagedJava = javaExecutable(in: staging), await matchesJava(stagedJava, major: major) else {
            throw LanternError("The downloaded Java runtime could not start on this Mac.")
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: staging, to: target)
        guard let executable = javaExecutable(in: target) else { throw LanternError("Java could not be located after setup.") }
        return executable
    }

    private func javaExecutable(in directory: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory,
                              includingPropertiesForKeys: nil) else { return nil }
        for child in children {
            let java = child.appendingPathComponent("Contents/Home/bin/java")
            if FileManager.default.isExecutableFile(atPath: java.path) { return java }
        }
        return nil
    }

    func matchesJava(_ executable: URL, major: Int) async -> Bool {
        guard let output = try? await Command.run(executable.path, ["-version"]) else { return false }
        return output.contains("version \"\(major).") || output.contains("version \"\(major)\"")
    }
}

private extension FileManager {
    func replaceOrMove(_ source: URL, to target: URL) throws -> URL {
        if fileExists(atPath: target.path) {
            return try replaceItemAt(target, withItemAt: source) ?? target
        }
        try moveItem(at: source, to: target)
        return target
    }
}
