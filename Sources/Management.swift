import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

extension ServerSettings {
    var options: [String:String] { profileOptions?[version] ?? [:] }
    mutating func put(_ key: String, _ value: String) {
        var profiles = profileOptions ?? [:]
        profiles[version, default: [:]][key] = value
        profileOptions = profiles
    }
}

enum ServerAlert: String, CaseIterable {
    case playerJoined, backupFailed, driveDisconnected

    var title: String {
        switch self {
        case .playerJoined: return "Player joined"
        case .backupFailed: return "Backup failed"
        case .driveDisconnected: return "Backup drive disconnected"
        }
    }
}

extension ServerModel {
    var software: String { settings.options["software"] ?? "Vanilla" }
    var backupFolder: URL {
        guard let value = settings.options["backupFolder"], !value.isEmpty else { return paths.backups }
        return URL(fileURLWithPath: value)
    }
    func chooseBackupDestination(_ folder: URL) throws {
        let destination: URL
        if paths.sharedRoot != nil {
            destination = folder.appendingPathComponent("Lantern-" + paths.root.lastPathComponent, isDirectory: true)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory) {
                guard directory.boolValue else { throw LanternError("Choose a backup folder.") }
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
        } else {
            destination = folder
        }
        settings.put("backupFolder", destination.resolvingSymlinksInPath().path)
    }

    var worldFolder: URL {
        let props = (try? String(contentsOf: selectedProfile.appendingPathComponent("server.properties"))) ?? ""
        let name = props.components(separatedBy: .newlines).first { $0.hasPrefix("level-name=") }.map { String($0.dropFirst(11)) } ?? option("level-name", "world")
        return selectedProfile.appendingPathComponent(name)
    }
    func option(_ key: String, _ fallback: String = "") -> String { settings.options[key] ?? fallback }
    func bind(_ key: String, _ fallback: String = "") -> Binding<String> {
        Binding(get: { self.option(key, fallback) }, set: { self.settings.put(key,$0) })
    }
    func flag(_ key: String, _ fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { self.option(key,String(fallback)) == "true" }, set: { self.settings.put(key,String($0)) })
    }
    var archiveList: [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = list.filter { $0.pathExtension == "zip" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return dated.sorted { ($0.1, $0.0.lastPathComponent) > ($1.1, $1.0.lastPathComponent) }.map { $0.0 }
    }
    func fileList(_ directory: URL) -> [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,options: [.skipsHiddenFiles])) ?? []
        return list.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    func choose(_ prompt: String, folders: Bool = false, files: Bool = true) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseDirectories = folders
        panel.canChooseFiles = files
        return panel.runModal() == .OK ? panel.url : nil
    }
    func saveTo(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }
    func confirm(_ title: String, _ message: String, _ action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }
    func fileTool(_ op: String, _ args: [String] = []) async throws -> String {
        let script: URL
        #if LANTERN_QA
        script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/worlds.py")
        #else
        guard let resource = Bundle.main.url(forResource: "worlds", withExtension: "py") else { throw LanternError("World tools are missing from the app bundle.") }
        script = resource
        #endif
        let encoded = try JSONEncoder().encode(settings)
        return try await Command.run("/usr/bin/python3", ["-B",script.path,op,selectedProfile.path,backupFolder.path,String(decoding: encoded, as: UTF8.self)] + args).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func operate(_ op: String, _ args: [String] = []) {
        guard ownsLock, !busy, !settings.version.isEmpty else { return }
        state = .backingUp
        activity = "Working on server files…"
        Task {
            defer { finishStopped(); completeQuitIfNeeded() }
            do {
                let result = try await fileTool(op,args)
                if op == "restore", let restored = try? JSONDecoder().decode(ServerSettings.self,from: Data(result.utf8)) {
                    var updated = restored
                    let currentVersion = settings.version
                    guard updated.version == currentVersion else { throw LanternError("Backup settings do not match the selected version.") }
                    var profiles = settings.profileOptions ?? [:]
                    profiles[currentVersion] = updated.options
                    updated.profileOptions = profiles
                    updated.put("backupFolder", backupFolder.path)
                    updated.acceptedEULA = settings.acceptedEULA
                    settings = updated
                    notice = "Server restored. A safety backup was saved first."
                } else { notice = result }
                activity = "Ready to start."
            } catch { errorMessage = error.localizedDescription; activity = "File operation stopped." }
        }
    }
    func backup(auto: Bool = false) {
        guard ownsLock, !backupWorking, hasWorld, state == .running || state == .stopped else { return }
        let live = state == .running
        let initialProcess = process
        if !live { state = .backingUp }
        backupWorking = true
        Task {
            var savesPaused = false
            defer {
                if savesPaused, process === initialProcess { writeCommand("save-on") }
                backupWorking = false
                if !live || (process == nil && state == .backingUp) { finishStopped() }
                if restartRequested && state == .stopped && !quitPending {restartRequested=false;start()}
                if sleepingAfterStop && state == .stopped {sleepingAfterStop=false;enterSleep()}
                if pendingStop { pendingStop = false; stop() }
                if state == .stopped { completeQuitIfNeeded() }
            }
            do {
                if live {
                    saveAcknowledged = false
                    writeCommand("save-off")
                    savesPaused = true
                    writeCommand("save-all flush")
                    let deadline = Date().addingTimeInterval(90)
                    while process === initialProcess && !saveAcknowledged && Date() < deadline {
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    guard process === initialProcess && saveAcknowledged else { throw LanternError("Minecraft did not confirm a completed save. Backup cancelled.") }
                }
                let result = try await fileTool(auto ? "auto" : "backup",[option("retention","8")])
                notice = "Backup saved: " + result
                settings.put("lastBackup", Date().formatted())
            } catch { errorMessage = "Backup failed. " + error.localizedDescription; notify(.backupFailed,error.localizedDescription) }
        }
    }
    func alertEnabled(_ event: ServerAlert) -> Bool {
        let legacy = event == .driveDisconnected ? "false" : option("notifications", "false")
        return option(event.rawValue, legacy) == "true"
    }

    func setAlert(_ event: ServerAlert, enabled: Bool) {
        settings.put(event.rawValue, String(enabled))
        if enabled {
            Task {
                do {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    if !granted { notice = "Allow Lantern alerts in System Settings → Notifications." }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func backupVolumeUnmounted(_ volume: URL) {
        let folder = backupFolder.standardizedFileURL.pathComponents
        guard alertEnabled(.driveDisconnected), folder.starts(with: volume.standardizedFileURL.pathComponents) else { return }
        notice = "Backup drive disconnected: " + volume.lastPathComponent
        notify(.driveDisconnected, volume.lastPathComponent)
    }

    func notify(_ event: ServerAlert, _ body: String) {
        guard alertEnabled(event), Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.subtitle = settings.displayName ?? "Minecraft server"
        content.body = body
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else if !otherServerNeedsLogin() { try SMAppService.mainApp.unregister() }
            settings.put("login",String(enabled))
        } catch { errorMessage = error.localizedDescription }
    }
    func commandNow(_ value: String) {
        guard state == .running,!backupWorking, !value.contains(where: { $0.isNewline }) else { return }
        command = value; sendCommand()
    }
    func startMonitoring() {
        monitoring?.cancel()
        taskDue.removeAll()
        let initial = Date()
        nextBackup = initial.addingTimeInterval(Double(Int(option("interval","30")) ?? 30)*60)
        monitoring = Task {
            var checks = 0
            while !Task.isCancelled, state == .running {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, state == .running, process != nil else { break }
                checks += 1
                runTasks()
                if let last = samples.last, Date().timeIntervalSince(last.id) > 15 {
                    samples.removeAll()
                }
                if checks % 6 == 1 {
                    if option("tickMonitor") == "true", supportsTickQuery { writeCommand("tick query") }
                    if option("batteryStop") == "true", let info = try? await Command.run("/usr/bin/pmset",["-g","batt"]),
                       info.contains("Battery Power"), let range = info.range(of: #"[0-9]+%"#, options:.regularExpression),
                       let percentage = Int(info[range].dropLast()), percentage <= (Int(option("batteryPercent","15")) ?? 15) {
                        writeCommand("say Low battery. Saving and stopping the server.")
                        stop()
                    }
                }
                let idle = Int(option("sleepMinutes","0")) ?? 0
                if idle > 0 && players.isEmpty && Date().timeIntervalSince(emptySince) >= Double(idle)*60 && !backupWorking {
                    sleepingAfterStop=true;stop();break
                }
                if Date() >= nextBackup {
                    nextBackup = Date().addingTimeInterval(Double(max(1,Int(option("interval","30")) ?? 30))*60)
                    if option("scheduled") == "true" { backup(auto:true) }
                }
            }
        }
    }
    var modernRules: Bool {
        let v=settings.version.split(separator:".").compactMap { Int($0) }
        return (v.first ?? 0) >= 26 || ((v.first == 1) && (v.dropFirst().first ?? 0) == 21 && (v.last ?? 0) >= 11 && v.count >= 3)
    }
    var supportsTickQuery: Bool {
        let v=settings.version.split(separator:".").compactMap { Int($0) }
        return modernRules || (v.count >= 2 && (v[1] > 20 || (v[1] == 20 && (v.count > 2 && v[2] >= 3))))
    }
    func applyRules() {
        for rule in GameRule.all {
            guard let value=settings.options["rule."+rule.new] else { continue }
            if !modernRules && rule.old.isEmpty { continue }
            let key = modernRules ? "minecraft:"+rule.new : rule.old
            let result = modernRules && rule.new == "fire_spread_radius_around_player" ? (value == "true" ? "128" : "0") : value
            writeCommand("gamerule "+key+" "+result)
        }
    }
}

struct GameRule {
    let title: String
    let old: String
    let new: String
    let initial: String
    static let all = [
        Self(title:"Keep inventory",old:"keepInventory",new:"keep_inventory",initial:"false"),
        Self(title:"Mob griefing",old:"mobGriefing",new:"mob_griefing",initial:"true"),
        Self(title:"Fire spreads",old:"doFireTick",new:"fire_spread_radius_around_player",initial:"true"),
        Self(title:"Daylight cycle",old:"doDaylightCycle",new:"advance_time",initial:"true"),
        Self(title:"Weather cycle",old:"doWeatherCycle",new:"advance_weather",initial:"true"),
        Self(title:"Instant respawn",old:"doImmediateRespawn",new:"immediate_respawn",initial:"false"),
        Self(title:"Player combat",old:"",new:"pvp",initial:"true"),
        Self(title:"Command blocks",old:"",new:"command_blocks_work",initial:"false"),
        Self(title:"Players needed for sleep (%)",old:"playersSleepingPercentage",new:"players_sleeping_percentage",initial:"100")
    ]
}

extension ServerModel {
    func testCopy(archive:URL?, disabled:[String]) {
        guard !busy,ownsLock,settings.acceptedEULA else {return}
        let profile=selectedProfile
        let source=archive?.path ?? ""
        state = .backingUp;activity="Loading a private test world…"
        Task {
            defer{finishStopped();completeQuitIfNeeded()}
            do {
                guard let version=versions.first(where:{$0.id==settings.version}) else{throw LanternError("Choose a game version first.")}
                let meta=try await downloads.details(for:version,profile:profile)
                guard let download=meta.downloads.server else{throw LanternError("No server download is available.")}
                let java=try await downloads.java(major:meta.javaVersion.majorVersion,in:paths.runtimes)
                let vanilla=try await downloads.server(download,in:profile)
                var launch=try await downloads.launchArguments(java:java,vanilla:vanilla,profile:profile,settings:settings)
                guard let index=launch.firstIndex(where:{$0=="-jar" || $0.hasPrefix("@")}) else{throw LanternError("Unsupported test launch arguments.")}
                launch=Array(launch[index...])
                if let i=launch.firstIndex(of:"nogui"){launch=Array(launch[...i])}
                notice=try await fileTool("trial",[source,java.path,try Catalog.json(launch),try Catalog.json(disabled)])
                activity="Private test finished."
            }catch{errorMessage=error.localizedDescription;activity="Private test stopped."}
        }
    }
    var restartChanges:[String] {
        guard let old=sessionSettings,state == .running else{return []}
        var result:[String]=[]
        for (name,a,b) in [("Memory (GB)",old.memoryGB,settings.memoryGB),("Player limit",old.maxPlayers,settings.maxPlayers),("Render distance",old.viewDistance ?? 10,settings.viewDistance ?? 10),("Simulation distance",old.simulationDistance ?? 10,settings.simulationDistance ?? 10)] where a != b {
            result.append("\(name): \(a) → \(b)")
        }
        for key in ["motd","white-list","hardcore","allow-flight","resource-pack","spawn-protection","player-idle-timeout","require-resource-pack"] where old.options[key] != settings.options[key] {
            result.append(key+": "+(old.options[key] ?? "server default")+" → "+option(key))
        }
        if !modernRules {
            for (key, title) in [("rule.pvp", "Player combat"), ("rule.command_blocks_work", "Command blocks")]
            where old.options[key] != settings.options[key] {
                result.append(title + ": " + (old.options[key] ?? "server default") + " → " + option(key))
            }
        }
        return result
    }
}

extension ServerModel {
    func saveAuthSettings(accounts:Bool, shared:Bool, password:String) throws {
        guard ownsLock,!busy,["Fabric","Paper"].contains(software) else {throw LanternError("Stop a Fabric or Paper server to configure AuthSmith.")}
        let cfg=selectedProfile.appendingPathComponent(software=="Fabric" ? "config/authsmith/config.yml" : "plugins/AuthSmith/config.yml")
        guard FileManager.default.fileExists(atPath:cfg.path) else {throw LanternError("Install the matching AuthSmith add-on and start it once to generate its configuration.")}
        if shared && (password.isEmpty || password.contains(where:{$0.isNewline})){throw LanternError("Enter a single-line invite password.")}
        var lines=try String(contentsOf:cfg,encoding:.utf8).components(separatedBy:.newlines)
        var block="",changed=Set<String>()
        for i in lines.indices {
            let line=lines[i]
            if !line.hasPrefix(" ") && !line.hasPrefix("#") {block=String(line.split(separator:":").first ?? "")}
            if ["server-password","accounts"].contains(block),line.hasPrefix("  enabled:"){
                lines[i]="  enabled: "+String(block=="accounts" ? accounts : shared);changed.insert(block)
            }
            if shared && block=="server-password",line.hasPrefix("  password:"){
                lines[i]="  password: '"+password.replacingOccurrences(of:"'",with:"''")+"'";changed.insert("password")
            }
        }
        guard changed.contains("accounts"),changed.contains("server-password"),!shared || changed.contains("password") else{throw LanternError("Unsupported AuthSmith configuration format.")}
        try lines.joined(separator:"\n").write(to:cfg,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:cfg.path)
    }
}

extension ServerModel {
    func testNetwork(internet:Bool) async -> String {
        var report:[String]=[]
        for (label,host) in [("This Mac","127.0.0.1"),("Mac’s LAN interface",localIP ?? "")] {
            guard !host.isEmpty else {report.append(label+" · no address");continue}
            do {
                _ = try await Command.run("/usr/bin/nc",["-z","-G","3",host,settings.port])
                report.append(label+" · reachable")
            } catch {report.append(label+" · could not connect")}
        }
        if internet {
            let address=option("publicAddress").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !address.isEmpty, address.range(of:"^[a-zA-Z0-9.:-]+$",options:.regularExpression) != nil,
                  let url=URL(string:"https://api.mcstatus.io/v2/status/java/"+address+"?query=false") else { return (report+["Internet · enter your public game address"]).joined(separator:"\n") }
            do {
                struct Status:Decodable {let online:Bool}
                let (data,response)=try await URLSession.shared.data(from:url)
                guard (response as? HTTPURLResponse)?.statusCode==200 else{throw LanternError("Status service unavailable")}
                let status=try JSONDecoder().decode(Status.self,from:data)
                report.append("Internet · "+(status.online ? "reachable" : "unreachable")+" according to mcstatus.io (may be cached)")
            }catch {report.append("Internet · check unavailable: "+error.localizedDescription)}
        }
        return report.joined(separator:"\n")
    }
    func upgrade(to target:String) {
        guard ownsLock,!busy,hasWorld,let next=versions.first(where:{$0.id==target}),let old=versions.first(where:{$0.id==settings.version}),next.releaseTime>old.releaseTime else{return}
        guard confirm("Upgrade "+old.id+" to "+target+"?","Lantern will archive "+old.id+" with its world and add-ons, then prepare a separate "+target+" profile. The old profile is available for rollback.","Prepare upgrade") else{return}
        let opts=settings.options
        state = .backingUp
        Task {
            defer{finishStopped();completeQuitIfNeeded()}
            do {
                let name=try await fileTool("upgrade",[target])
                var new=settings
                new.version=target
                var profiles=new.profileOptions ?? [:]
                profiles[target]=opts
                new.profileOptions=profiles
                new.put("resume","false")
                for key in ["PaperJar","NeoForgeJar"] {new.put(key,"")}
                settings=new
                notice="Prepared "+target+". Roll back by selecting "+old.id+". Safety backup: "+name
            }catch{errorMessage=error.localizedDescription}
        }
    }
}

struct TimedTask: Codable,Identifiable {
    var id=UUID()
    var name:String
    var command:String
    var minutes:Int
    var enabled=true
}
extension ServerModel {
    var timedTasks:[TimedTask] {
        get{(try? JSONDecoder().decode([TimedTask].self,from:Data(option("tasks","[]").utf8))) ?? []}
        set{if let data=try? JSONEncoder().encode(newValue){settings.put("tasks",String(decoding:data,as:UTF8.self))}}
    }
    func runTasks() {
        for task in timedTasks where task.enabled {
            let interval=Double(max(1,task.minutes))*60
            guard let due=taskDue[task.id] else{taskDue[task.id]=Date().addingTimeInterval(interval);continue}
            if Date()>=due && !backupWorking {
                taskDue[task.id]=Date().addingTimeInterval(interval)
                if task.command.isEmpty{backup(auto:true)}else{commandNow(task.command)}
            }
        }
    }
    func updateAddon(_ jar:URL) {
        guard ownsLock,!busy else{return}
        state = .backingUp
        Task {
            defer{finishStopped();completeQuitIfNeeded()}
            do {
                guard let (change,file,originalHash)=try await Catalog.newer(for:jar,version:settings.version,loader:software) else{notice="This add-on is already up to date.";return}
                guard confirm("Update "+jar.lastPathComponent+"?",change+"\nLantern will create a full backup before replacement.","Update") else{return}
                let (tmp,response)=try await URLSession.shared.download(from:file.url)
                defer{try? FileManager.default.removeItem(at:tmp)}
                guard (response as? HTTPURLResponse)?.statusCode==200,try ServerFiles.digest(tmp)==file.hashes["sha1"],try ServerFiles.digest(jar)==originalHash else {throw LanternError("Add-on verification failed.")}
                let backupName=try await fileTool("backup")
                let stage=jar.deletingLastPathComponent().appendingPathComponent(".update-"+UUID().uuidString)
                try FileManager.default.copyItem(at:tmp,to:stage)
                defer{try? FileManager.default.removeItem(at:stage)}
                _=try FileManager.default.replaceItemAt(jar,withItemAt:stage)
                notice="Updated "+jar.lastPathComponent+". Rollback backup: "+backupName
            }catch{errorMessage=error.localizedDescription}
        }
    }
}

extension ServerModel {
    func chooseLoaderJar() {
        guard ownsLock,!busy,["Paper","NeoForge"].contains(software),let src=choose("Use for "+software),src.pathExtension.lowercased()=="jar" else{return}
        do {
            let folder=selectedProfile.appendingPathComponent("server-software")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let dest=folder.appendingPathComponent(src.lastPathComponent)
            if src.standardizedFileURL != dest.standardizedFileURL {
                let stage=folder.appendingPathComponent(".install-"+UUID().uuidString)
                defer{try? FileManager.default.removeItem(at:stage)}
                try FileManager.default.copyItem(at:src,to:stage)
                if FileManager.default.fileExists(atPath:dest.path){_=try FileManager.default.replaceItemAt(dest,withItemAt:stage)}
                else{try FileManager.default.moveItem(at:stage,to:dest)}
            }
            settings.put(software+"Jar",src.lastPathComponent)
        }catch{errorMessage=error.localizedDescription}
    }
}

extension ServerModel {
    func configureAddon(_ jar:URL?, restore:Bool) {
        guard ownsLock,!busy else{return}
        let panel=NSOpenPanel()
        let root=selectedProfile.appendingPathComponent(software=="Paper" ? "plugins":"config")
        let prefix=jar?.deletingPathExtension().lastPathComponent.split(separator:"-").first.map(String.init)?.lowercased()
        panel.directoryURL=prefix.flatMap{key in fileList(root).first{$0.hasDirectoryPath && $0.lastPathComponent.lowercased().hasPrefix(key)}} ?? root
        panel.prompt=restore ? "Restore previous settings" : "Edit settings"
        guard panel.runModal() == .OK,let file=panel.url,["json","json5","yaml","yml","toml","properties","conf"].contains(file.pathExtension) else{return}
        do {
            let dest=file.resolvingSymlinksInPath()
            guard dest.path.hasPrefix(selectedProfile.resolvingSymlinksInPath().path+"/") else{throw LanternError("Choose a configuration file in this server folder.")}
            let previous=dest.appendingPathExtension("lantern-previous")
            if restore {
                guard FileManager.default.fileExists(atPath:previous.path) else{throw LanternError("There is no saved previous version of this file.")}
                guard confirm("Restore "+dest.lastPathComponent+"?","This restores the settings saved before the last edit.","Restore") else{return}
                try Data(contentsOf:previous).write(to:dest,options:.atomic)
                notice="Restored "+dest.lastPathComponent
            }else{
                try Data(contentsOf:dest).write(to:previous,options:.atomic)
                if let editor=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.TextEdit"){
                    NSWorkspace.shared.open([dest],withApplicationAt:editor,configuration:NSWorkspace.OpenConfiguration())
                }else{NSWorkspace.shared.open(dest)}
            }
        }catch{errorMessage=error.localizedDescription}
    }
}
