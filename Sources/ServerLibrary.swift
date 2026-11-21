import Combine
import SwiftUI

@MainActor
final class ServerLibrary: ObservableObject {
    @Published private(set) var servers: [ServerModel]
    @Published private(set) var selected: ServerModel
    private let base: URL
    private let downloads = Downloads()
    private var unmountObserver: AnyCancellable?
    private var loaded = false
    private var instances: URL { base.appendingPathComponent("Instances", isDirectory: true) }
    private var selectionFile: URL { base.appendingPathComponent("selected-server") }

    init(root: URL? = nil) {
        base = ServerPaths(root: root).root
        let original = ServerModel(root: base, downloads: downloads)
        servers = [original]
        selected = original
        guard original.ownsLock else { return }
        do {
            if FileManager.default.fileExists(atPath: instances.path) {
                let entries = try FileManager.default.contentsOfDirectory(at: instances, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                for url in entries.sorted(by: { $0.path < $1.path }) where UUID(uuidString: url.lastPathComponent) != nil {
                    let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard info.isDirectory == true, info.isSymbolicLink != true,
                          FileManager.default.fileExists(atPath: url.appendingPathComponent("settings.json").path) else { continue }
                    servers.append(ServerModel(root: url, sharedRoot: base, downloads: downloads))
                }
            }
            let id = try? String(contentsOf: selectionFile, encoding: .utf8)
            selected = servers.first { $0.paths.root.lastPathComponent == id } ?? original
        } catch { original.errorMessage = error.localizedDescription }
        for server in servers { connect(server) }
        unmountObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                self?.servers.forEach { $0.backupVolumeUnmounted(volume) }
            }
    }

    private func connect(_ model: ServerModel) {
        model.otherServerNeedsLogin = { [weak self, weak model] in
            self?.servers.contains { $0 !== model && $0.option("login") == "true" } ?? false
        }
        model.otherServerUsingPort = { [weak self, weak model] port in
            self?.servers.contains { $0 !== model && $0.busy && UInt16(($0.sessionSettings ?? $0.settings).port) == port } ?? false
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        for server in servers { Task { await server.loadVersions() } }
    }

    func select(_ server: ServerModel) {
        guard servers.first?.ownsLock == true, servers.contains(where: { $0 === server }) else { return }
        selected = server
        do { try server.paths.root.lastPathComponent.write(to: selectionFile, atomically: true, encoding: .utf8) }
        catch { server.errorMessage = error.localizedDescription }
    }

    @discardableResult func create(name: String) throws -> ServerModel {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard servers.first?.ownsLock == true, !name.isEmpty else { throw LanternError("Enter a server name in the main Foxfire window.") }
        let used = Set(servers.compactMap { UInt16($0.settings.port) })
        guard let port = (UInt16(25565)...UInt16.max).first(where: { !used.contains($0) && ServerFiles.portIsAvailable($0) }) else {
            throw LanternError("No available server port was found.")
        }
        let folder = instances.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var configuration = ServerSettings()
        configuration.displayName = name
        configuration.port = String(port)
        configuration.version = selected.settings.version
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: folder.appendingPathComponent("settings.json"), options: .atomic)
        let server = ServerModel(root: folder, sharedRoot: base, downloads: downloads)
        connect(server)
        servers.append(server)
        select(server)
        if loaded { Task { await server.loadVersions() } }
        return server
    }

    func beginQuit() -> NSApplication.TerminateReply {
        var waiting = false
        for server in servers {
            if server.beginQuit() == .terminateCancel { waiting = true }
        }
        return waiting ? .terminateCancel : .terminateNow
    }
}

struct ServerSwitcher: View {
    @ObservedObject var library: ServerLibrary
    @ObservedObject var current: ServerModel
    @ViewState<Bool> private var adding = false
    @ViewState<String> private var name = ""

    var body: some View {
        Menu {
            ForEach(library.servers, id: \.paths.root) { server in
                ServerChoice(model: server, selected: server === current) { library.select(server) }
            }
            Divider()
            Button("New server…") { name = ""; adding = true }
        } label: {
            Label(current.settings.displayName ?? "My Minecraft server", systemImage: "server.rack")
                .lineLimit(1)
        }
        .accessibilityLabel("Switch server")
        .accessibilityValue(current.settings.displayName ?? "My Minecraft server")
        .alert("New server", isPresented: $adding) {
            TextField("Server name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                do { try library.create(name: name) }
                catch { current.errorMessage = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct ServerChoice: View {
    @ObservedObject var model: ServerModel
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            let title = (model.settings.displayName ?? "My Minecraft server") + " · " + model.state.label + " · " + model.settings.port
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
