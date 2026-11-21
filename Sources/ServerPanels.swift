import SwiftUI
import AppKit
import UserNotifications

struct ServerPanels: View {
    @ObservedObject var model: ServerModel
    let section: DashboardSection
    @ViewState<String> private var username = ""
    @ViewState<String> private var search = ""
    @ViewState<String> private var message = ""
    @ViewState<[CatalogHit]> private var hits = []
    @ViewState<[CatalogRelease]> private var releases = []
    @ViewState<String> private var projectTitle = ""
    @ViewState<String> private var label = ""
    @ViewState<String> private var taskName = ""
    @ViewState<String> private var taskCommand = ""
    @ViewState<Int> private var taskMinutes = 30
    @ViewState<String> private var favorite = ""
    @ViewState<Set<String>> private var trialDisabled = []
    @ViewState<String> private var playerID = ""
    @ViewState<String> private var selectedLog = ""
    @ViewState<String> private var logText = ""
    @ViewState<String> private var logFilter = ""
    @ViewState<Bool> private var accounts = true
    @ViewState<Bool> private var shared = false
    @ViewState<String> private var invitePassword = ""
    @ViewState<String> private var upgradeVersion = ""
    @ViewState<String> private var permission = ""
    @ViewState<Int> private var refresh = 0
    @ViewState<Bool> private var searching = false

    private var fm: FileManager { .default }
    private var packs: URL { model.worldFolder.appendingPathComponent("datapacks") }
    private var jars: URL { model.selectedProfile.appendingPathComponent(model.software == "Paper" ? "plugins" : "mods") }
    private var validUser: Bool { username.range(of:"^[A-Za-z0-9_]{1,16}$",options:.regularExpression) != nil }
    private var version: String { model.settings.version }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            switch section {
            case .world: worlds
            case .addons: addons
            case .players: players
            case .network: network
            case .backups: backups
            case .settings: settings
            case .overview: overview
            case .console: consoleTools
            case .performance: EmptyView()
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.onChange(of:model.settings.version) { _,_ in hits=[]; releases=[]; message="" }
    }
    private func group<C:View>(_ title:String,@ViewBuilder content:()->C)->some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(16)
            .background(.white.opacity(0.052),in:RoundedRectangle(cornerRadius:12))
    }
    private func text(_ title:String,_ key:String,_ initial:String="")->some View {
        LabeledContent(title) { TextField(title,text:model.bind(key,initial)).textFieldStyle(.roundedBorder).frame(maxWidth:300) }
    }
    private func toggle(_ title:String,_ key:String,_ initial:Bool=false)->some View {
        Toggle(title,isOn:model.flag(key,initial))
    }
    private func count(_ title:String,_ key:String,_ initial:Int,_ range:ClosedRange<Int>)->some View {
        let n=Int(model.option(key,String(initial))) ?? initial
        return Stepper("\(title) · \(n)",value:Binding(get:{n},set:{model.settings.put(key,String($0))}),in:range)
    }
    private func button(_ title:String,_ action:@escaping () throws -> Void)->some View {
        Button(title) {
            do { try action(); refresh += 1 } catch { message=error.localizedDescription }
        }
    }
    private var worlds:some View {
        Group {
            group("World files") {
                Text(model.worldFolder.lastPathComponent).font(.callout.monospaced())
                HStack {
                    Button("Import folder or ZIP…") {
                        guard let file=model.choose("Import world",folders:true) else {return}
                        if model.confirm("Import into "+version+"?", "Replace "+model.worldFolder.lastPathComponent+" with "+file.lastPathComponent+". Foxfire will back up the current world first.","Import") {model.operate("import",[file.path])}
                    }
                    Button("Export world ZIP…") { if let url=model.saveTo(model.worldFolder.lastPathComponent+".zip"){model.operate("export",[url.path])} }
                    Button("Open server folder"){model.showFiles()}
                }
            }.disabled(model.busy)
            group("New world") {
                text("World name","level-name","world")
                text("Seed","level-seed")
                Picker("Terrain",selection:model.bind("level-type","minecraft:normal")) {
                    ForEach(["normal","flat","large_biomes","amplified"],id:\.self){Text($0.replacingOccurrences(of:"_",with:" ").capitalized).tag("minecraft:"+$0)}
                }
                toggle("Hardcore · death leaves the player in spectator mode","hardcore")
                Text("Choose these before the first start of a new world.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy || fm.fileExists(atPath:model.worldFolder.appendingPathComponent("level.dat").path))
            group("Game rules") {
                HStack { ForEach(["Default","Relaxed","Builder"],id:\.self){ preset in
                    Button(preset) {
                        for rule in GameRule.all {
                            var value=rule.initial
                            if preset != "Default" {
                                if ["keep_inventory","immediate_respawn"].contains(rule.new) {value="true"}
                                if ["fire_spread_radius_around_player","mob_griefing","pvp"].contains(rule.new){value="false"}
                                if rule.new=="players_sleeping_percentage"{value="1"}
                            }
                            if preset=="Builder" && ["advance_time","advance_weather"].contains(rule.new){value="false"}
                            model.settings.put("rule."+rule.new,value)
                        }
                        if model.state == .running {model.applyRules()}
                    }
                }}
                ForEach(GameRule.all,id:\.new){ rule in
                    if rule.new=="players_sleeping_percentage"{count(rule.title,"rule."+rule.new,100,0...100)}
                    else {toggle(rule.title,"rule."+rule.new,rule.initial=="true")}
                }
                Button("Apply rules now"){model.applyRules()}.disabled(model.state != .running)
                count("Spawn protection (blocks)","spawn-protection",16,0...128)
                count("Idle player timeout (minutes, 0 disables)","player-idle-timeout",0,0...240)
                toggle("Allow modded flight","allow-flight")
            }
            group("Spawn and world border") {
                TextField("Player at the new spawn point",text:$username)
                Button("Set spawn at player"){model.commandNow("execute at "+username+" run setworldspawn ~ ~ ~")}.disabled(!validUser)
                text("Border center X","borderX","0")
                text("Border center Z","borderZ","0")
                text("Border diameter (blocks)","diameter","8000")
                Button("Apply world border"){
                    guard let x=Int(model.option("borderX","0")),let z=Int(model.option("borderZ","0")),let d=Int(model.option("diameter","8000")),(1...59999968).contains(d) else {message="Enter a valid center and diameter.";return}
                    model.commandNow("worldborder center \(x) \(z)");model.commandNow("worldborder set \(d)")
                }
            }.disabled(model.state != .running)
        }
    }
    private func listFiles(_ directory:URL,pack:Bool)->some View {
        let files=model.fileList(directory).filter { pack || $0.pathExtension=="jar" || $0.pathExtension=="disabled" }
        return VStack(alignment:.leading,spacing:8) {
            ForEach(files,id:\.self){file in
                HStack {
                    Text(file.lastPathComponent).lineLimit(2);Spacer()
                    if !pack && file.pathExtension=="jar" {Button("Configure…"){model.configureAddon(file,restore:false)};Button("Check update…"){model.updateAddon(file)}}
                    button(file.pathExtension=="disabled" ? "Enable":"Disable"){
                        let target = file.pathExtension=="disabled" ? file.deletingPathExtension() : file.appendingPathExtension("disabled")
                        if pack && file.hasDirectoryPath {
                            let holding=model.worldFolder.appendingPathComponent("lantern-disabled-packs")
                            try fm.createDirectory(at:holding,withIntermediateDirectories:true)
                            try fm.moveItem(at:file,to:holding.appendingPathComponent(file.lastPathComponent))
                        } else {try fm.moveItem(at:file,to:target)}
                    }
                }
            }
            if pack {
                let holding=model.worldFolder.appendingPathComponent("lantern-disabled-packs")
                ForEach(model.fileList(holding),id:\.self){file in
                    HStack {Text(file.lastPathComponent);Spacer();button("Enable"){try fm.moveItem(at:file,to:directory.appendingPathComponent(file.lastPathComponent))}}
                }
            }
            if files.isEmpty {Text("No installed files.").foregroundStyle(.secondary)}
        }.id(refresh)
    }
    private var addons:some View {
        Group {
            group("World datapacks") {
                listFiles(packs,pack:true)
                Button("Add datapack folder or ZIP…"){if let file=model.choose("Add datapack",folders:true){model.operate("pack",[file.path])}}
            }.disabled(model.busy)
            if model.software != "Vanilla" {
                group(model.software=="Paper" ? "Paper plugins":"Installed mods") {
                    listFiles(jars,pack:false)
                    button("Install local JAR…"){
                        guard let file=model.choose("Install JAR"),file.pathExtension.lowercased()=="jar" else{return}
                        try fm.createDirectory(at:jars,withIntermediateDirectories:true)
                        try fm.copyItem(at:file,to:jars.appendingPathComponent(file.lastPathComponent))
                    }
                    Button("Restore previous add-on settings…"){model.configureAddon(nil,restore:true)}
                }.disabled(model.busy)
                group("Test a copy of this setup") {
                    Text("Select add-ons to leave out of the test. The test uses a temporary world and a separate local game port.")
                    ForEach(model.fileList(jars).filter{$0.pathExtension=="jar"},id:\.self){url in
                        Toggle(url.lastPathComponent,isOn:Binding(get:{trialDisabled.contains(url.lastPathComponent)},set:{on in
                            if on{trialDisabled.insert(url.lastPathComponent)}else{trialDisabled.remove(url.lastPathComponent)}
                        }))
                    }
                    Button("Run private startup test"){model.testCopy(archive:nil,disabled:Array(trialDisabled))}
                }.disabled(model.busy || !model.settings.acceptedEULA)
                group("Find add-ons on Modrinth") {
                    HStack {ForEach(["AuthSmith","LuckPerms","SkinRestorer",model.software=="Paper" ? "EssentialsX":"Essential Commands"],id:\.self){name in
                        Button(name){search=name;find()}.disabled(searching)
                    }}
                    HStack {TextField("Add-on name",text:$search);Button("Search"){find()}.disabled(searching)}
                    ForEach(hits){hit in HStack {Text(hit.title);Spacer();Button("Releases"){showReleases(hit)}.disabled(searching || model.busy)}}
                    if !releases.isEmpty {
                        Text("Compatible releases · "+projectTitle).font(.headline)
                        ForEach(releases.prefix(20)){release in HStack{Text(release.version_number);Spacer();Button("Install"){install(release)}.disabled(searching || model.busy)}}
                    }
                }
            } else {Text("Select Fabric, NeoForge, or Paper in Settings to install mods or plugins.")}
        }
    }
    private func find() {
        searching=true; hits=[]; releases=[]
        let v=version, loader=model.software
        Task { defer {searching=false}
            do { let result=try await Catalog.search(search,version:v,loader:loader)
                if v==version && loader==model.software { hits=result;message=result.isEmpty ? "No compatible results.":"" }
            } catch {message=error.localizedDescription}
        }
    }
    private func showReleases(_ hit:CatalogHit) {
        let v=version, loader=model.software
        searching=true
        Task {
            defer{searching=false}
            do{
                let choices=try await Catalog.releases(hit,version:v,loader:loader)
                if version==v && model.software==loader{releases=choices;projectTitle=hit.title;message=choices.isEmpty ? "No matching release.":""}
            }catch{message=error.localizedDescription}
        }
    }
    private func install(_ release:CatalogRelease) {
        guard !model.busy,model.ownsLock else{return}
        let folder=jars
        model.state = .backingUp;searching=true
        Task {defer{model.finishStopped();model.completeQuitIfNeeded();searching=false;refresh+=1}
            do {message="Installed "+(try await Catalog.install(release,root:folder))}
            catch {message=error.localizedDescription}
        }
    }
    private var players:some View {
        group("Manage players") {
            TextField("Minecraft username",text:$username)
            if !model.players.isEmpty {HStack{ForEach(model.players.sorted(),id:\.self){name in Button(name){username=name}}}}
            HStack {ForEach(["Allow","Remove from list","Grant operator","Remove operator"],id:\.self){action in
                Button(action){let verbs=["Allow":"whitelist add","Remove from list":"whitelist remove","Grant operator":"op","Remove operator":"deop"]
                    if let verb=verbs[action]{model.commandNow(verb+" "+username)}}
            }}.disabled(!validUser)
            if model.software != "Vanilla" {
                TextField("Permission node for LuckPerms",text:$permission)
                HStack{ForEach(["Grant","Revoke"],id:\.self){action in Button(action){
                    model.commandNow("lp user "+username+" permission "+(action=="Grant" ? "set "+permission+" true":"unset "+permission))
                }}}.disabled(!validUser || permission.range(of:"^[a-zA-Z0-9_.-]+$",options:.regularExpression)==nil)
            }
            HStack {ForEach(["Kick","Ban","Unban"],id:\.self){action in Button(action){model.commandNow((action=="Unban" ? "pardon" : action.lowercased())+" "+username)}}}.disabled(!validUser)
            HStack {Button("Enable allowlist"){model.commandNow("whitelist on");model.settings.put("white-list","true")};Button("Disable allowlist"){model.commandNow("whitelist off");model.settings.put("white-list","false")};Button("List allowed players"){model.commandNow("whitelist list")}}
            Text("Minecraft reports command results in Console.").font(.caption)
        }.disabled(model.state != .running)
    }
    private var network:some View {
        group("Server list and access") {
            text("Public description","motd")
            text("Resource pack URL","resource-pack")
            toggle("Require resource pack","require-resource-pack")
            toggle("Friends-only allowlist","white-list")
            if ["Fabric","Paper"].contains(model.software){
                DisclosureGroup("AuthSmith login settings") {
                    Toggle("Individual player accounts",isOn:$accounts)
                    Toggle("Shared invite password",isOn:$shared)
                    if shared{SecureField("Invite password",text:$invitePassword)}
                    button("Save login settings"){
                        try model.saveAuthSettings(accounts:accounts,shared:shared,password:invitePassword)
                        invitePassword="";message="Login settings saved for next start."
                    }
                    Text("Install AuthSmith from Add-ons first. Its protection applies in offline mode.").font(.caption)
                }
            }
            text("Public join address","publicAddress")
            HStack {
                Button("Test Mac and LAN"){Task{message=await model.testNetwork(internet:false)}}
                Button("Test internet via mcstatus.io"){Task{message=await model.testNetwork(internet:true)}}.disabled(model.option("publicAddress").isEmpty)
            }
            Button("Copy public join address"){
                NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.option("publicAddress"),forType:.string)
            }.disabled(model.option("publicAddress").isEmpty)
            Link("Set up a free Java tunnel with playit",destination:URL(string:"https://playit.gg/download/macos")!)
            button("Choose paired playit agent…"){
                if let file=model.choose("Choose playit executable"),fm.isExecutableFile(atPath:file.path){model.settings.put("playitPath",file.path)}
            }
            if !model.option("playitPath").isEmpty {
                toggle("Start tunnel with server","tunnelAuto")
                Button(model.tunnelProcess == nil ? "Start tunnel agent":"Stop tunnel agent"){if model.tunnelProcess == nil {model.startTunnel()}else{model.stopTunnel()}}
            }
            Text("Point the Minecraft Java tunnel at localhost:"+model.settings.port+". Copy the public address into this field to share it.")
            Text("For a direct internet connection, forward your chosen TCP port on your router to the Mac’s LAN address. Friends at home use your public address and port.").font(.callout)
        }
    }
    private var backups:some View {
        Group {
            group("Automatic backups") {
                toggle("Back up when the server stops","onStop")
                toggle("Schedule backups during play","scheduled")
                count("Interval (minutes)","interval",30,1...1440)
                count("Automatic backups to keep","retention",8,1...100)
                Text("Last successful backup · "+model.option("lastBackup","None recorded"))
                HStack {
                    Button("Back up now"){model.backup()}.disabled(!model.hasWorld || model.backupWorking || !(model.state == .running || model.state == .stopped))
                    Button("Choose storage…"){if let folder=model.choose("Use for backups",folders:true,files:false){do { try model.chooseBackupDestination(folder) } catch { message=error.localizedDescription }}}
                    Button("Google Drive…"){
                        let locations=fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
                        let accounts=model.fileList(locations).filter{$0.lastPathComponent.hasPrefix("GoogleDrive-")}
                        guard let account=accounts.first else{message="Sign in to Google Drive for desktop, then choose a synced folder.";return}
                        let panel=NSOpenPanel();panel.directoryURL=accounts.count==1 ? account : locations
                        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.prompt="Use Drive folder"
                        if panel.runModal() == .OK,let folder=panel.url {do { try model.chooseBackupDestination(folder) } catch { message=error.localizedDescription }}
                    }
                    Button("Open folder"){model.showFiles(backups:true)}
                }
                if let free=try? model.backupFolder.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity,free < 10_737_418_240 {
                    Text("Backup drive has under 10 GB free.").foregroundStyle(.orange)
                }
                Text(model.backupFolder.path).font(.caption).textSelection(.enabled)
                Button("Check disk usage"){Task {do{message=try await model.fileTool("disk")}catch{message=error.localizedDescription}}}
                Text("For Google Drive, choose a folder in Google Drive for desktop. Drive handles syncing.").font(.caption).foregroundStyle(.secondary)
            }
            group("Scheduled tasks") {
                ForEach(model.timedTasks){task in
                    HStack {
                        Toggle(task.name+" · every "+String(task.minutes)+" min",isOn:Binding(get:{task.enabled},set:{on in
                            var tasks=model.timedTasks
                            if let i=tasks.firstIndex(where:{$0.id==task.id}){tasks[i].enabled=on;model.timedTasks=tasks;model.taskDue[task.id]=nil}
                        }))
                        Spacer();Button("Remove"){model.timedTasks=model.timedTasks.filter{$0.id != task.id};model.taskDue[task.id]=nil}
                    }
                }
                TextField("Task name",text:$taskName)
                TextField("Server command (leave empty for a backup)",text:$taskCommand)
                Stepper("Every "+String(taskMinutes)+" minutes",value:$taskMinutes,in:1...1440)
                Button("Add task"){model.timedTasks.append(.init(name:taskName,command:taskCommand,minutes:taskMinutes));taskName="";taskCommand=""}.disabled(taskName.isEmpty)
            }
            group("Saved backups") {
                TextField("Milestone name",text:$label)
                ForEach(model.archiveList,id:\.self){file in
                    let pin=file.deletingPathExtension().appendingPathExtension("pin")
                    HStack {
                        VStack(alignment:.leading){Text(file.lastPathComponent).lineLimit(2);if let name=try? String(contentsOf:pin){Text(name).foregroundStyle(.green)}}
                        Spacer()
                        button(fm.fileExists(atPath:pin.path) ? "Unpin":"Pin"){
                            if fm.fileExists(atPath:pin.path){try fm.removeItem(at:pin)}else{try (label.isEmpty ? "Milestone" : label).write(to:pin,atomically:true,encoding:.utf8)}
                        }
                        Button("Restore…"){restore(file)}.disabled(model.busy)
                    }
                }
                Button("Export server to another Mac…"){if let file=model.saveTo("Foxfire-"+version+".zip"){model.operate("migration",[file.path])}}.disabled(model.busy)
                Button("Test a backup privately…"){if let file=model.choose("Test backup"){model.testCopy(archive:file,disabled:[])}}.disabled(model.busy || !model.settings.acceptedEULA)
                if let data=try? Data(contentsOf:model.selectedProfile.appendingPathComponent("usercache.json")), let users=try? JSONSerialization.jsonObject(with:data) as? [[String:Any]] {
                    Picker("Recover player",selection:$playerID){Text("Choose a player").tag("");ForEach(users.compactMap{row -> String? in guard let name=row["name"] as? String,let id=row["uuid"] as? String else{return nil};return name+" "+id}.sorted(),id:\.self){item in
                        Text(String(item.split(separator:" ").first ?? "")).tag(String(item.split(separator:" ").last ?? ""))
                    }}
                }
                TextField("Player UUID for inventory recovery",text:$playerID)
                Button("Recover inventory from backup…"){
                    if let file=model.choose("Choose player's backup"),model.confirm("Restore this inventory and Ender Chest?","Foxfire will back up the current server before changing the selected player.","Recover"){model.operate("inventory",[file.path,playerID])}
                }.disabled(UUID(uuidString:playerID)==nil || model.busy)
                Button("Restore backup from file…"){if let file=model.choose("Choose server backup"){restore(file)}}.disabled(model.busy)
            }.id(refresh)
        }
    }
    private func restore(_ file:URL) {
        if model.confirm("Restore "+file.lastPathComponent+"?", "The current "+version+" server will be backed up first. Restoring a full backup replaces its world, players, settings and add-ons.","Restore"){model.operate("restore",[file.path])}
    }
    private var settings:some View {
        Group {
            group("Server loader") {
                if let current=model.versions.first(where:{$0.id==version}), model.hasWorld {
                    let newer=model.versions.filter{$0.releaseTime>current.releaseTime}
                    if !newer.isEmpty {
                        Picker("Upgrade current world",selection:$upgradeVersion){
                            Text("Choose a newer release").tag("")
                            ForEach(newer){v in Text(v.id).tag(v.id)}
                        }
                        Button("Review server upgrade…"){model.upgrade(to:upgradeVersion)}.disabled(upgradeVersion.isEmpty)
                    }
                }
                Button("Open guided setup"){model.showSetup=true}
                Picker("Software",selection:model.bind("software","Vanilla")){ForEach(["Vanilla","Fabric","NeoForge","Paper"],id:\.self){Text($0).tag($0)}}
                if ["Paper","NeoForge"].contains(model.software) {
                    Button(model.software == "Paper" ? "Choose Paper server JAR…" : "Choose NeoForge installer JAR…"){
                        model.chooseLoaderJar()
                    }
                    Text(model.option(model.software+"Jar","Choose a build for Minecraft "+version)).font(.caption)
                }
                Button("Apply Mac performance preset"){
                    model.settings.viewDistance=8;model.settings.simulationDistance=5
                    model.settings.put("entity-broadcast-range-percentage","80")
                }
                Text("Preset: 8 chunks of terrain, 5 simulation chunks, 80% entity broadcast range.").font(.caption)
                text("Java executable (blank for automatic)","javaPath")
                text("Extra JVM argument","javaFlags");text("Extra server argument","serverArgs")
            }.disabled(model.busy)
            group("Mac hosting") {
                count("Sleep after empty (minutes, 0 disables)","sleepMinutes",0,0...240)
                text("Sleeping server message","sleepMessage","Sleeping · join to wake up")
                text("Wake-up message","wakeMessage","Starting the server. Join again shortly.")
                toggle("Warn players and stop on low battery","batteryStop")
                count("Battery threshold (%)","batteryPercent",15,5...90)
                Toggle("Resume hosting after Mac login",isOn:Binding(get:{model.option("login")=="true"},set:{model.setLogin($0)}))
                Text("Mac notifications").font(.subheadline.weight(.semibold))
                ForEach(ServerAlert.allCases, id: \.self) { event in
                    Toggle(event.title, isOn: Binding(get: { model.alertEnabled(event) },
                                                       set: { model.setAlert(event, enabled: $0) }))
                }
                toggle("Restart after crashes (two attempts)","crashRestart")
                toggle("Sample tick timing in Console","tickMonitor")
                if let report=model.fileList(model.selectedProfile.appendingPathComponent("crash-reports")).last {
                    Button("Open latest crash report"){NSWorkspace.shared.open(report)}
                }
            }
        }
    }
    private var overview:some View {
        group("Server details") {
            if !model.restartChanges.isEmpty {
                Text("Needs restart · "+String(model.players.count)+" online").foregroundStyle(.orange)
                ForEach(model.restartChanges,id:\.self){ Text($0) }
                Button("Save and restart…", action: model.confirmRestart)
                    .disabled(model.state != .running || model.backupWorking)
            }
            LabeledContent("Software",value:model.software+" · "+version)
            LabeledContent("Changed rule settings",value:String(model.settings.options.keys.filter{$0.hasPrefix("rule.")}.count))
            LabeledContent("Installed add-on files",value:String(model.fileList(packs).filter{!$0.lastPathComponent.hasSuffix(".disabled")}.count+(model.software=="Vanilla" ? 0 : model.fileList(jars).filter{$0.pathExtension=="jar"}.count)))
            LabeledContent("Last backup",value:model.option("lastBackup","None recorded"))
            let total=Double(ProcessInfo.processInfo.physicalMemory)/1073741824
            if Double(model.settings.memoryGB)>total*0.65 {Text("Your server limit leaves under 35% of this Mac’s memory for Minecraft and other apps.").foregroundStyle(.orange)}
        }
    }
    private var consoleTools:some View {
        DisclosureGroup("Saved commands and previous logs") {
            VStack(alignment:.leading) {
                HStack { TextField("Button name",text:$label);TextField("Minecraft command",text:$favorite)
                    Button("Pin"){model.settings.put("pin."+label,favorite);label="";favorite=""}.disabled(label.isEmpty || favorite.isEmpty) }
                ForEach(model.settings.options.keys.filter{$0.hasPrefix("pin.")}.sorted(),id:\.self){key in
                    HStack {Button(String(key.dropFirst(4))){model.commandNow(model.option(key))}.disabled(model.state != .running)
                        Button("Unpin"){model.settings.profileOptions?[version]?.removeValue(forKey:key)}}
                }
                HStack {TextField("Search log text",text:$logFilter)
                    Button("Choose dated log…") {
                        let panel=NSOpenPanel();panel.directoryURL=model.selectedProfile.appendingPathComponent("logs")
                        guard panel.runModal() == .OK,let url=panel.url else{return}
                        Task {do {
                            if url.pathExtension=="gz" {logText=try await Command.run("/usr/bin/gzip",["-dc",url.path])}
                            else {logText=try String(contentsOf:url,encoding:.utf8)}
                            selectedLog=url.lastPathComponent
                        } catch {message=error.localizedDescription}}
                    }}
                if !selectedLog.isEmpty {Text(selectedLog).font(.caption); ScrollView {Text(logText.components(separatedBy:.newlines).filter{logFilter.isEmpty || $0.localizedCaseInsensitiveContains(logFilter)}.suffix(250).joined(separator:"\n")).font(.caption.monospaced()).textSelection(.enabled)}.frame(maxHeight:130)}
            }
        }
    }
}
