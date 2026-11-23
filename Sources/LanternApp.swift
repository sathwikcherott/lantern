import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var library: ServerLibrary?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        library?.beginQuit() ?? .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

#if !LANTERN_QA
@main
struct LanternApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library: ServerLibrary

    init() {
        signal(SIGPIPE, SIG_IGN)
        let override = ProcessInfo.processInfo.environment["LANTERN_HOME"].map { URL(fileURLWithPath: $0) }
        _library = StateObject(wrappedValue: ServerLibrary(root: override))
    }

    var body: some Scene {
        Window("Lantern", id: "main") {
            ContentView(model: library.selected, library: library)
                .id(library.selected.paths.root)
                .onAppear {
                    delegate.library = library
                    library.load()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }

        }
        .defaultSize(width: 1020, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Server") {
                ServerActions(model: library.selected)
            }
        }
        MenuBarExtra {
            LanternMenu(model: library.selected)
        } label: {
            Image(nsImage: LanternIcon.creeper)
                .renderingMode(.template)
                .accessibilityLabel("Lantern")
        }

    }

}
#endif

@MainActor
private enum LanternIcon {
    static let creeper: NSImage = {
        // Two points per pixel keeps the Creeper silhouette sharp at menu-bar size.
        let rows = [
            "########",
            "########",
            "#..##..#",
            "#..##..#",
            "###..###",
            "##....##",
            "##....##",
            "##.##.##"
        ]
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, pixel) in row.enumerated() where pixel == "#" {
                    NSBezierPath(rect: NSRect(x: 1 + 2*x, y: 1 + 2*y, width: 2, height: 2)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lantern"
        return image
    }()
}

struct ServerActions: View {
    @ObservedObject var model: ServerModel
    var body: some View {
        Button("Start Server") { model.start() }.disabled(!model.canStart)
        Button("Stop Server") { model.stop() }.disabled(!model.hosting)
        Divider()
        Button("Copy Join Address") { model.copyAddress() }.disabled(model.joinAddress == nil)
        Button("Open Server Folder") { model.showFiles() }.disabled(model.settings.version.isEmpty)
        Button("Open Backups") { model.showFiles(backups: true) }
    }
}

struct LanternMenu: View {
    @ObservedObject var model: ServerModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.settings.displayName ?? "My Minecraft server")
        Text(model.state.label+" · "+String(model.players.count)+" online")
        Button("Open Lantern"){openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}
        Button("Copy join address"){model.copyAddress()}.disabled(model.joinAddress == nil)
        Button("Start server") { model.start() }.disabled(!model.canStart)
        Button("Stop server"){model.stop()}.disabled(!model.hosting)
        Button("Quit Lantern"){NSApp.terminate(nil)}
    }
}

enum DashboardSection: String, CaseIterable {
    case overview = "Overview", world = "World", addons = "Add-ons", players = "Players"
    case performance = "Performance"
    case network = "Network", backups = "Backups", console = "Console", settings = "Settings"

    var icon: String {
        switch self {
        case .performance: return "gauge.medium"
        case .overview: return "square.grid.2x2"
        case .world: return "mountain.2"
        case .addons: return "puzzlepiece.extension"
        case .players: return "person.2"
        case .network: return "network"
        case .backups: return "externaldrive"
        case .console: return "terminal"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: ServerModel
    private let accent = Color(red: 0.31, green: 0.85, blue: 0.49)
    private let background = Color(red: 0.067, green: 0.076, blue: 0.069)
    private let panel = Color(red: 0.115, green: 0.13, blue: 0.12)

    @ViewState<DashboardSection> var section = .overview
    @ViewState<Bool> private var renaming = false
    @ViewState<String> private var draftName = ""

    let library: ServerLibrary?

    init(model: ServerModel, section: DashboardSection = .overview, library: ServerLibrary? = nil) {
        self.library = library
        self.model = model
        _section = ViewState(initialValue: section)
    }

    private var serverName: String { model.settings.displayName ?? "My Minecraft server" }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(section.rawValue).font(.system(size: 26, weight: .bold))
                    Spacer()
                    Label(model.state.label, systemImage: "circle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(statusColor)
                }.padding(.horizontal, 28).padding(.vertical, 20)
                Divider()
                if section == .console {
                    VStack(alignment: .leading, spacing: 10) { messages; ServerPanels(model:model,section:.console); console }.padding(24)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            messages
                            pageContent
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(26)
                    }.id(section)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .disabled(!model.ownsLock)
        .frame(minWidth: 820, minHeight: 600)
        .background(background).preferredColorScheme(.dark).tint(accent)
        .sheet(isPresented:$model.showSetup){Onboarding(model:model)}
        .alert("Edit server name", isPresented: $renaming) {
            TextField("Server name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                model.settings.displayName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            }.disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("This name identifies the server in Lantern.") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(nsImage: LanternIcon.creeper)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text("Lantern").fontWeight(.bold)
            }.font(.system(size: 22, design: .rounded)).padding(.leading, 10).padding(.vertical, 18)
            if let library { ServerSwitcher(library: library, current: model).padding(.bottom, 8) }
            ForEach(DashboardSection.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.icon).frame(width: 20)
                        Text(item.rawValue).fontWeight(section == item ? .semibold : .regular).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .contentShape(Rectangle())
                    .background(section == item ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).foregroundStyle(section == item ? accent : Color.primary.opacity(0.85))
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer()
            Divider().padding(.vertical, 8)
            Label("Hosted on this Mac", systemImage: "laptopcomputer").font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 4).padding(.bottom, 8)
        }.padding(.horizontal, 12).frame(width: 200)
        .background(Color(red: 0.087, green: 0.102, blue: 0.092))
    }

    @ViewBuilder private var pageContent: some View {
        switch section {
        case .overview:
            serverControl
            eula
            card("Live performance") {
                OverviewGauges(model: model)
                Button("View performance") { section = .performance }
            }
            card("Quick settings") { distanceAndMemory }
            connection
            ServerPanels(model:model,section:.overview)
            DisclosureGroup("Technical details") {
                LabeledContent("Server software", value: model.software+" Java Edition")
                LabeledContent("Minecraft version", value: model.settings.version)
                LabeledContent("Server port", value: model.settings.port)
            }.font(.callout)
        case .performance:
            card("Server performance") { PerformanceReadout(model: model) }
        case .world:
            card("World settings") { gameSettings.disabled(model.busy) }
            ServerPanels(model:model,section:.world)
        case .addons:
            ServerPanels(model:model,section:.addons)
        case .players:
            card("Online players · \(model.players.count) / \(model.settings.maxPlayers)") {
                if model.players.isEmpty { Text("Nobody is connected.").foregroundStyle(.secondary) }
                ForEach(model.players.sorted(), id: \.self) { player in Label(player, systemImage: "person.fill") }
            }
            ServerPanels(model:model,section:.players)
            Button("Open server console") { section = .console }
        case .network:
            card("Join addresses") { connection }
            ServerPanels(model:model,section:.network)
            card("Player access") { networkSettings.disabled(model.busy) }
        case .backups:
            ServerPanels(model:model,section:.backups)
        case .settings:
            card("Server software") { versionSettings.disabled(model.busy); eula }
            ServerPanels(model:model,section:.settings)
            card("Performance and capacity") { distanceAndMemory }
            Text("Keep your Mac awake and the lid open while hosting.").foregroundStyle(.secondary)
        case .console: EmptyView()
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusColor: Color {
        switch model.state {
        case .running: return accent
        case .stopped: return .gray
        default: return .orange
        }
    }

    private var versionSettings: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    fieldLabel("Minecraft version")
                    Spacer()
                    if model.loadingVersions { ProgressView().controlSize(.mini) }
                    else {
                        Button { Task { await model.loadVersions() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Refresh available versions")
                        .accessibilityLabel("Refresh Minecraft versions")
                        .disabled(model.busy)
                    }
                }
                Picker("Minecraft version", selection: $model.settings.version) {
                    if model.versions.isEmpty { Text("Loading versions…").tag(model.settings.version) }
                    else {
                        ForEach(model.versions) { version in Text(version.id).tag(version.id) }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Text("1.18 and newer. Each version keeps its own world.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
    }
    private var gameSettings: some View {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Game mode")
                    Picker("Game mode", selection: $model.settings.gameMode) {
                        Text("Survival").tag("survival")
                        Text("Creative").tag("creative")
                        Text("Adventure").tag("adventure")
                    }.labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Difficulty")
                    Picker("Difficulty", selection: $model.settings.difficulty) {
                        ForEach(["peaceful", "easy", "normal", "hard"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.labelsHidden()
                }
            }
    }
    private var networkSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Port")
                    TextField("25565", text: $model.settings.port)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Server port")
                }
            }
            Toggle("Allow unverified players (offline mode)", isOn: Binding(
                get: { model.launchSettings.allowUnverified == true }, set: { model.settings.allowUnverified = $0 }
            )).toggleStyle(.switch).font(.caption)
            if model.launchSettings.allowUnverified == true {
                Text("Players can use any name. Switching an existing world to offline mode can change which inventory a player sees.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var eula: some View {
            if !model.settings.acceptedEULA {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("I agree to the Minecraft EULA", isOn: $model.settings.acceptedEULA)
                        .font(.system(size: 12))
                        .toggleStyle(.checkbox)
                    Link("Read Minecraft’s EULA ↗", destination: URL(string: "https://www.minecraft.net/eula")!)
                        .font(.system(size: 11))
                    Text("Missing Minecraft and Java files download automatically.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }
    }
    @ViewBuilder private var distanceAndMemory: some View {
        let current = model.sessionSettings ?? model.launchSettings
        if model.busy {
            Label("Stop the server to edit these settings.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 26), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            settingSlider("Server memory", unit: "GB", range: 1...model.maxMemory,
                          value: model.busy ? .constant(current.memoryGB) : $model.settings.memoryGB, hint: "Maximum Java heap (1–10 GB).")
            settingSlider("Render distance", unit: "chunks", range: 3...32,
                          value: Binding(get: { current.viewDistance ?? 10 }, set: { model.settings.viewDistance = $0 }),
                          hint: "How far the server sends terrain to players.")
            settingSlider("Simulation distance", unit: "chunks", range: 3...32,
                          value: Binding(get: { current.simulationDistance ?? 10 }, set: { model.settings.simulationDistance = $0 }),
                          hint: "How far mobs and other game logic stay active.")
            settingSlider("Player limit", unit: "players", range: 1...50, value: model.busy ? .constant(current.maxPlayers) : $model.settings.maxPlayers, hint: "Maximum simultaneous players.")
        }
        .disabled(model.busy)
        .saturation(model.busy ? 0 : 1)
        .opacity(model.busy ? 0.7 : 1)
    }

    private func settingSlider(_ title: String, unit: String, range: ClosedRange<Int>, value: Binding<Int>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text("\(value.wrappedValue) \(unit)").font(.callout.monospacedDigit()).foregroundStyle(model.busy ? Color.secondary : accent)
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .accessibilityLabel(title).accessibilityValue("\(value.wrappedValue) \(unit)")
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Friends on the same Wi-Fi").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { model.refreshAddress() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Refresh your Mac’s network address")
                    .accessibilityLabel("Refresh network address")
            }
            HStack(spacing: 6) {
                Text(model.joinAddress ?? "Connect to Wi-Fi")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Button { model.copyAddress() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .help("Copy the address for friends")
                    .accessibilityLabel("Copy join address")
                    .disabled(model.joinAddress == nil)
                Spacer(minLength: 10)
                Button("Copy localhost") { model.copyAddress(local: true) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
            }
            .padding(11)
            .background(panel, in: RoundedRectangle(cornerRadius: 7))
            Text("Multiplayer → Direct Connection. Match the server’s game version.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private var serverControl: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ServerIconPicker(profile: model.selectedProfile, enabled: !model.busy && !model.settings.version.isEmpty)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(serverName).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                        Button {
                            draftName = serverName
                            renaming = true
                        } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).help("Edit server name").accessibilityLabel("Edit server name")
                    }
                    Text("Minecraft Java · \(model.software) \(model.settings.version)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 14)
                if model.state == .sleeping {
                    Button("Wake server") {model.wakeServer()}
                } else if model.state == .preparing {
                    Button("Cancel") { model.stop() }.controlSize(.large)
                } else if model.state == .backingUp || model.state == .stopping {
                    ProgressView().controlSize(.small).padding(8)
                } else {
                    VStack(spacing: 6) {
                        Button { model.busy ? model.stop() : model.start() } label: {
                            Label(model.busy ? "Stop server" : "Start server", systemImage: model.busy ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ServerControlButtonStyle(fill: model.busy ? .red : accent))
                        .disabled(!model.busy && !model.canStart)
                        .keyboardShortcut(.return, modifiers: [.command])

                        if model.state == .running {
                            Button(action: model.confirmRestart) {
                                Label("Restart server", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ServerControlButtonStyle(fill: .yellow))
                            .disabled(model.backupWorking)
                        }
                    }
                    .frame(width: 124)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(background)
                }
            }
            Text(model.state == .stopped && !model.settings.acceptedEULA ? "Review the Minecraft EULA before your first start." : model.activity).font(.callout).foregroundStyle(.secondary)
            if model.state == .preparing || model.state == .starting || model.state == .stopping || model.state == .backingUp {
                ProgressView().progressViewStyle(.linear)
            }
            if model.state == .running {
                HStack(spacing: 20) {
                    if let start = model.startedAt {
                        Label { Text(start, style: .timer).monospacedDigit() } icon: { Image(systemName: "clock") }
                    }
                    Label("\(model.players.count) / \(model.settings.maxPlayers) players", systemImage: "person.2")
                    Label("\((model.sessionSettings?.memoryGB ?? model.settings.memoryGB)) GB heap limit", systemImage: "memorychip")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if model.canForceStop {
                Button("Force stop…", role: .destructive) { model.forceStop() }
            }
        }
        .padding(20)
        .background(LinearGradient(colors: [accent.opacity(0.14), panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(error).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.clearError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss error")
            }
            .padding(12)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
        if let notice = model.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(accent).textSelection(.enabled)
        }
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.logs.isEmpty {
                    Button("Copy log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.logs, forType: .string)
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            Divider().opacity(0.5)
            if model.logs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 25)).foregroundStyle(.secondary)
                    Text("Server activity appears here").font(.system(size: 13, weight: .medium))
                    Text("Start your server to see world loading,\nplayer connections and commands.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.logs)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(red: 0.77, green: 0.81, blue: 0.77))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                            Color.clear.frame(height: 1).id("end")
                        }.padding(14)
                    }
                    .onChange(of: model.logs) { _, _ in proxy.scrollTo("end", anchor: .bottomLeading) }
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Text(">").font(.system(size: 14, design: .monospaced)).foregroundStyle(accent)
                TextField("Server command, e.g. op YourUsername", text: $model.command)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit { model.sendCommand() }
                    .accessibilityLabel("Server command")
                Button { model.sendCommand() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(model.state == .running ? accent : .gray)
                    .accessibilityLabel("Send command")
            }
            .disabled(model.state != .running)
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

private struct ServerControlButtonStyle: ButtonStyle {
    let fill: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
