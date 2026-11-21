import AppKit
import SwiftUI
import Darwin

@MainActor
final class ServerModel: ObservableObject {
    enum State: Equatable {
        case stopped, preparing, starting, running, stopping, backingUp, sleeping
        var label: String {
            switch self {
            case .sleeping: return "Sleeping"
            case .stopped: return "Stopped"
            case .preparing: return "Setting up"
            case .starting: return "Starting"
            case .running: return "Running"
            case .stopping: return "Saving world"
            case .backingUp: return "Backing up"
            }
        }
    }

    @Published var settings: ServerSettings {
        didSet {
            if oldValue.options["interval"] != settings.options["interval"] {
                nextBackup=Date().addingTimeInterval(Double(max(1,Int(option("interval","30")) ?? 30))*60)
            }
            saveSettings()
        }
    }
    @Published private(set) var versions: [MinecraftVersion] = []
    @Published var state: State = .stopped
    @Published var activity = "Choose a version to get started."
    @Published private(set) var logs = ""
    @Published private(set) var localIP = ServerFiles.localAddress()
    @Published private(set) var loadingVersions = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var startedAt: Date?
    @Published private(set) var players: Set<String> = []
    @Published private(set) var canForceStop = false
    @Published var command = ""

    @Published var showSetup = false
    @Published var backupWorking = false
    @Published var samples: [PerformanceSample] = []
    @Published var tickInfo = ""
    @Published var tunnelProcess: Process?
    var sleepProcess: Process?
    var restartRequested = false
    var wakeRequested = false
    var sleepingAfterStop = false
    var emptySince = Date()
    var pendingStop = false
    var saveAcknowledged = false
    var monitoring: Task<Void, Never>?
    var sessionSettings: ServerSettings?
    var taskDue: [UUID:Date] = [:]
    var nextBackup = Date()
    private var checkedResume = false
    private var crashAttempts = 0

    let paths: ServerPaths
    let maxMemory: Int
    let downloads: Downloads
    var otherServerNeedsLogin: () -> Bool = { false }
    var otherServerUsingPort: (UInt16) -> Bool = { _ in false }
    var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pendingOutput = Data()
    private var outputEnded = false
    private var processEnded = false
    private var setupTask: Task<Void, Never>?
    private var stopTimeout: Task<Void, Never>?
    private var awakeActivity: NSObjectProtocol?
    var quitPending = false
    private var lockFD: Int32 = -1
    var ownsLock = false

    var busy: Bool { state != .stopped }
    var hosting: Bool { process != nil }
    var joinAddress: String? { localIP.map { "\($0):\(settings.port)" } }
    var selectedProfile: URL { paths.profile(settings.version) }
    var hasWorld: Bool {
        FileManager.default.fileExists(atPath: worldFolder.appendingPathComponent("level.dat").path) ||
            (state == .running && FileManager.default.fileExists(atPath: selectedProfile.appendingPathComponent("server.properties").path))
    }
    var canStart: Bool {
        !busy && !backupWorking && ownsLock && settings.acceptedEULA && versions.contains(where: { $0.id == settings.version })
    }

    init(root: URL? = nil, sharedRoot: URL? = nil, downloads: Downloads = Downloads()) {
        self.downloads = downloads
        paths = ServerPaths(root: root, sharedRoot: sharedRoot)
        maxMemory = 10
        let saved = try? Data(contentsOf: paths.settings)
        var configuration = saved.flatMap { try? JSONDecoder().decode(ServerSettings.self, from: $0) } ?? ServerSettings()
        configuration.memoryGB = min(maxMemory, max(1, configuration.memoryGB))
        settings = configuration
        do {
            try paths.createDirectories()
            lockFD = open(paths.root.appendingPathComponent(".instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw LanternError("Foxfire is already open. Use its existing window to manage your server.")
            }
            ownsLock = true
        } catch { errorMessage = error.localizedDescription }
    }

    deinit {
        if lockFD >= 0 { close(lockFD) }
    }

    private func saveSettings() {
        guard ownsLock else { return }
        do { try JSONEncoder().encode(settings).write(to: paths.settings, options: .atomic) }
        catch { errorMessage = "Your settings could not be saved. \(error.localizedDescription)" }
    }

    func loadVersions() async {
        guard !loadingVersions, ownsLock else { return }
        loadingVersions = true
        errorMessage = nil
        defer { loadingVersions = false }
        do {
            let manifest = try await downloads.manifest(at: paths.manifest)
            versions = manifest.supportedReleases
            if settings.version.isEmpty { settings.version = manifest.latest.release }
            if !versions.contains(where: { $0.id == settings.version }) {
                throw LanternError("The saved Minecraft version is unavailable. Choose a version from the list.")
            }
            if state == .stopped { activity = "Ready when you are." }
            if !checkedResume {
                checkedResume = true
                if !settings.acceptedEULA && option("setupComplete") != "true" { showSetup = true }
                if option("login") == "true", option("resume") == "true", canStart { start() }
            }
        } catch {
            errorMessage = "Couldn’t load Minecraft versions. \(error.localizedDescription)"
        }
    }

    // Resolve values from older profiles until the user explicitly edits the controls.
    var launchSettings: ServerSettings {
        var result = settings
        let file = selectedProfile.appendingPathComponent("server.properties")
        let previous = try? String(contentsOf: file, encoding: .utf8)
        var values: [String: String] = [:]
        for line in (previous ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        result.viewDistance = min(32, max(3, result.viewDistance ?? Int(values["view-distance"] ?? "") ?? 10))
        result.simulationDistance = min(32, max(3, result.simulationDistance ?? Int(values["simulation-distance"] ?? "") ?? 10))
        result.allowUnverified = result.allowUnverified ?? (previous == nil || values["online-mode"] == "false")
        return result
    }

    func start() {
        guard canStart else { return }
        guard let port = UInt16(settings.port), port >= 1024 else {
            errorMessage = "Choose a port between 1024 and 65535. The usual Minecraft port is 25565."
            return
        }
        guard !otherServerUsingPort(port), ServerFiles.portIsAvailable(port) else {
            errorMessage = "Port \(port) is already in use. Stop the other server or choose another port."
            return
        }
        guard let version = versions.first(where: { $0.id == settings.version }) else { return }
        let configuration = launchSettings
        sessionSettings = configuration
        state = .preparing
        errorMessage = nil
        notice = nil
        logs = ""
        players = []
        pendingOutput = Data()
        outputEnded = false
        processEnded = false
        localIP = ServerFiles.localAddress()
        awakeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "Hosting a Minecraft server")
        setupTask = Task {
            defer {
                setupTask = nil
                if process == nil {
                    finishStopped()
                    completeQuitIfNeeded()
                }
            }
            do {
                let profile = paths.profile(configuration.version)
                try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                activity = "Checking Minecraft \(version.id)…"
                if software != "Vanilla" { _ = try await fileTool("check") }
                let details = try await downloads.details(for: version, profile: profile)
                guard let download = details.downloads.server else {
                    throw LanternError("Mojang does not provide a dedicated server for this version.")
                }
                try Task.checkCancellation()
                activity = "Preparing Java \(details.javaVersion.majorVersion)… First setup may download about 220 MB."
                let java: URL
                if let override=configuration.options["javaPath"], !override.isEmpty {
                    java = URL(fileURLWithPath:override)
                    guard await downloads.matchesJava(java,major:details.javaVersion.majorVersion) else { throw LanternError("Choose Java "+String(details.javaVersion.majorVersion)+" for this Minecraft version.") }
                } else { java = try await downloads.java(major: details.javaVersion.majorVersion, in: paths.runtimes) }
                try Task.checkCancellation()
                activity = "Preparing Minecraft \(version.id)… First setup downloads the server."
                let server = try await downloads.server(download, in: profile)
                try Task.checkCancellation()
                try ServerFiles.writeProperties(at: profile.appendingPathComponent("server.properties"), settings: configuration)
                try "eula=true\n".write(to: profile.appendingPathComponent("eula.txt"), atomically: true, encoding: .utf8)
                let arguments = try await downloads.launchArguments(java:java, vanilla:server, profile:profile, settings:configuration)
                try Task.checkCancellation()
                try launch(java: java, arguments: arguments, profile: profile, settings: configuration)
            } catch is CancellationError {
                activity = "Setup cancelled. You can start again anytime."
            } catch let error as URLError where error.code == .cancelled {
                activity = "Setup cancelled. You can start again anytime."
            } catch {
                errorMessage = error.localizedDescription
                activity = "Server stopped."
            }
        }
    }

    private func launch(java: URL, arguments: [String], profile: URL, settings: ServerSettings) throws {
        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        child.executableURL = java
        child.currentDirectoryURL = profile
        if let agent = Bundle.main.url(forResource: "LanternMetrics", withExtension: "jar") {
            child.arguments = ["-javaagent:" + agent.path] + arguments
        } else {
            child.arguments = arguments
        }
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stdoutPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                if data.isEmpty {
                    self.outputEnded = true
                    self.finishIfEnded(child)
                } else { self.receive(data, from: child) }
            }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                self.processEnded = true
                self.finishIfEnded(child)
            }
        }
        process = child
        input = stdinPipe
        output = stdoutPipe
        do { try child.run() }
        catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            process = nil
            input = nil
            output = nil
            throw error
        }
        state = .starting
        activity = "Starting Minecraft… A new world can take a minute."
        appendLog("[Foxfire] Starting Minecraft \(settings.version) with \(settings.memoryGB) GB of memory.")
    }

    private func receive(_ data: Data, from child: Process) {
        guard process === child else { return }
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 10) {
            let line = String(decoding: pendingOutput[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            pendingOutput.removeSubrange(...newline)
            if let sample = PerformanceSample(line) {
                samples = Array(samples.suffix(149)) + [sample]
                continue
            }
            appendLog(line)
            if backupWorking && !saveAcknowledged && line.contains("Saved the game") {
                saveAcknowledged = Self.isSaveConfirmation(line)
            }
            if line.contains("Average time per tick:") || (line.contains("[Server thread/INFO]") && line.contains("mspt")) { tickInfo = String(line.suffix(120)) }
            if line.contains("Done ("), line.contains("For help"), state == .starting {
                state = .running
                startedAt = Date()
                settings.put("resume","true")
                applyRules()
                emptySince = Date()
                startMonitoring()
                if option("tunnelAuto") == "true" {startTunnel()}
                activity = "Your world is ready. Friends can join over the same Wi-Fi."
            }
            if let range = line.range(of: "]: "), line.hasSuffix(" joined the game") {
                notify(.playerJoined, String(line[range.upperBound...]))
                players.insert(String(line[range.upperBound...].dropLast(" joined the game".count)))
            }
            if let range = line.range(of: "]: "), line.hasSuffix(" left the game") {
                players.remove(String(line[range.upperBound...].dropLast(" left the game".count)))
                if players.isEmpty { emptySince = Date() }
            }
        }
    }

    static func isSaveConfirmation(_ line: String) -> Bool {
        // Paper redraws its console prompt. Only accept the server's complete status message.
        let visible = (line.components(separatedBy: "\r").last ?? line)
            .replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let prefix = #"^(?:\[\d{2}:\d{2}:\d{2} INFO\]|\[[a-zA-Z0-9:. -]+\] \[Server thread/INFO\](?: \[[a-zA-Z0-9._/-]+\])?)"#
        return visible.range(of: prefix + #": (?:System chat: )?Saved the game$"#,
                             options: .regularExpression) != nil
    }

    private func appendLog(_ line: String) {
        logs += line + "\n"
        if logs.utf8.count > 200_000 {
            logs = String(logs.suffix(150_000))
            if let newline = logs.firstIndex(of: "\n") { logs.removeSubrange(...newline) }
        }
    }

    private func finishIfEnded(_ child: Process) {
        guard process === child, processEnded, outputEnded else { return }
        output?.fileHandleForReading.readabilityHandler = nil
        if !pendingOutput.isEmpty { appendLog(String(decoding: pendingOutput, as: UTF8.self)) }
        pendingOutput = Data()
        let stoppedNormally = state == .stopping
        if child.terminationStatus != 0 && !stoppedNormally {
            errorMessage = "Minecraft exited with code \(child.terminationStatus). Check the console below for details."
        }
        appendLog("[Foxfire] Server stopped (exit \(child.terminationStatus)).")
        process = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        activity = "Server stopped. Your world is saved on this Mac."
        monitoring?.cancel()
        samples.removeAll()
        tickInfo = ""
        if !sleepingAfterStop && !restartRequested {stopTunnel()}
        let clean = stoppedNormally && child.terminationStatus == 0
        if backupWorking { state = .backingUp; return }
        finishStopped()
        if clean && option("onStop") == "true" { backup(auto:true); return }
        if clean && restartRequested && !quitPending {restartRequested=false;start();return}
        restartRequested=false
        if clean && sleepingAfterStop {sleepingAfterStop=false;enterSleep();return}
        sleepingAfterStop=false
        if !stoppedNormally && child.terminationStatus != 0 && option("crashRestart") == "true" && !quitPending && crashAttempts < 2 {
            crashAttempts += 1
            start(); return
        }
        completeQuitIfNeeded()
    }

    func confirmRestart() {
        guard state == .running, !backupWorking, let child = process else { return }
        let details = (restartChanges + ["Connected players: \(players.count). Players can rejoin after restart."]).joined(separator: "\n")
        guard confirm("Save and restart the server?", details, "Restart"),
              process === child, state == .running, !backupWorking else { return }
        restartRequested = true
        writeCommand("say Server restart in progress. Please rejoin shortly.")
        stop()
    }

    func stop() {
        if !busy { return }
        if backupWorking { pendingStop = hosting; return }
        settings.put("resume","false")
        crashAttempts = 0
        if let sleeper=sleepProcess {if sleeper.isRunning {sleeper.terminate()};return}
        if state == .preparing {
            activity = "Cancelling setup…"
            setupTask?.cancel()
            return
        }
        guard let child = process, state != .stopping else { return }
        state = .stopping
        activity = "Saving the world and stopping Minecraft…"
        writeCommand("stop")
        stopTimeout = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, process === child else { return }
            canForceStop = true
            activity = "Minecraft is taking longer to stop. Check the console before forcing it to close."
        }
    }

    func forceStop() {
        guard let child = process else { return }
        let alert = NSAlert()
        alert.messageText = "Force stop Minecraft?"
        alert.informativeText = "Changes that Minecraft has not saved may be lost."
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Force Stop")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        kill(child.processIdentifier, SIGKILL)
    }

    func writeCommand(_ value: String) {
        guard let child = process, child.isRunning else { return }
        do { try input?.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8)) }
        catch { errorMessage = "The command could not be sent. \(error.localizedDescription)" }
    }

    func sendCommand() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .running, !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { return }
        let cleaned = value.hasPrefix("/") ? String(value.dropFirst()) : value
        command = ""
        if cleaned == "stop" { stop(); return }
        appendLog("> \(cleaned)")
        writeCommand(cleaned)
    }

    func backUp() { backup() }

    func finishStopped() {
        sessionSettings = nil
        state = .stopped
        startedAt = nil
        players = []
        canForceStop = false
        stopTimeout?.cancel()
        stopTimeout = nil
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
    }

    func beginQuit() -> NSApplication.TerminateReply {
        if quitPending { return .terminateCancel }
        stopTunnel()
        guard busy else { return .terminateNow }
        quitPending = true
        if state != .backingUp { stop() }
        // Keep the regular event loop alive while process output and saves finish.
        // A fresh termination request follows once all work has completed.
        return .terminateCancel
    }

    func completeQuitIfNeeded() {
        guard quitPending else { return }
        quitPending = false
        NSApplication.shared.terminate(nil)
    }

    func refreshAddress() { localIP = ServerFiles.localAddress() }
    func clearError() { errorMessage = nil }

    func copyAddress(local: Bool = false) {
        guard let address = local ? "localhost:\(settings.port)" : joinAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        notice = "Copied \(address)."
    }

    func showDatapacks() {
        let properties = selectedProfile.appendingPathComponent("server.properties")
        let lines = (try? String(contentsOf: properties, encoding: .utf8))?.components(separatedBy: .newlines) ?? []
        let world = lines.first(where: { $0.hasPrefix("level-name=") }).map { String($0.dropFirst(11)) } ?? "world"
        let directory = selectedProfile.appendingPathComponent(world).appendingPathComponent("datapacks")
        guard FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("level.dat").path) else {
            errorMessage = "Start this world and let it finish loading before opening its datapacks folder."
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(directory) { throw LanternError("Finder could not open the datapacks folder.") }
        } catch { errorMessage = error.localizedDescription }
    }

    func showFiles(backups: Bool = false) {
        let folder = backups ? backupFolder : selectedProfile
        if backups && !FileManager.default.fileExists(atPath:folder.path) {errorMessage="Reconnect your backup drive or choose another folder.";return}
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { errorMessage = error.localizedDescription }
    }
}
