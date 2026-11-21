import SwiftUI

struct Onboarding: View {
    @ObservedObject var model:ServerModel
    @ViewState<Int> private var step=0
    @Environment(\.dismiss) var dismiss
    let steps=["Name your server","Choose Minecraft version","Choose server software","Allocate memory","Set up the world","Choose backups","Connect friends","Review and finish"]
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            HStack{Text("Guided setup").font(.title2.bold());Spacer();Text("\(step+1) of \(steps.count)").foregroundStyle(.secondary)}
            ProgressView(value:Double(step+1),total:Double(steps.count))
            Text(steps[step]).font(.headline)
            Group {
                switch step {
                case 0:TextField("Server name",text:Binding(get:{model.settings.displayName ?? ""},set:{model.settings.displayName=$0}))
                case 2:Picker("Server software",selection:model.bind("software","Vanilla")){ForEach(["Vanilla","Fabric","NeoForge","Paper"],id:\.self){Text($0).tag($0)}}
                    if ["Paper","NeoForge"].contains(model.software){Button("Choose matching server or installer JAR…"){model.chooseLoaderJar()}}
                case 1:Picker("Game version",selection:$model.settings.version){ForEach(model.versions){v in Text(v.id).tag(v.id)}}
                case 3:Text("Server memory · \(model.settings.memoryGB) GB")
                    Slider(value:Binding(get:{Double(model.settings.memoryGB)},set:{model.settings.memoryGB=Int($0)}),in:1...10,step:1)
                case 4:Picker("Game mode",selection:$model.settings.gameMode){ForEach(["survival","creative","adventure"],id:\.self){Text($0.capitalized).tag($0)}}
                    Picker("Difficulty",selection:$model.settings.difficulty){ForEach(["peaceful","easy","normal","hard"],id:\.self){Text($0.capitalized).tag($0)}}
                    Text("Import an existing save from World before you start the server.")
                case 5:Toggle("Back up after each session",isOn:model.flag("onStop"));Toggle("Schedule backups during play",isOn:model.flag("scheduled"))
                case 6:Text(model.joinAddress ?? "Connect to your home network.");Toggle("Friends-only allowlist",isOn:model.flag("white-list"))
                    Toggle("Allow unverified players",isOn:Binding(get:{model.launchSettings.allowUnverified == true},set:{model.settings.allowUnverified=$0}))
                default:Text("\(model.settings.displayName ?? "My Minecraft server") · \(model.software) \(model.settings.version)")
                    Text("\(model.settings.memoryGB) GB · \(model.settings.gameMode) · \(model.settings.difficulty)")
                    Toggle("I agree to the Minecraft EULA",isOn:$model.settings.acceptedEULA)
                    Link("Read Minecraft’s EULA",destination:URL(string:"https://www.minecraft.net/eula")!)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
            Spacer()
            HStack{Button("Close"){dismiss()};Spacer();if step>0{Button("Back"){step-=1}}
                Button(step==7 ? "Finish" : "Continue"){if step==7{model.settings.put("setupComplete","true");dismiss()}else{step+=1}}.buttonStyle(.borderedProminent)}
        }.padding(24).frame(width:470,height:330)
    }
}
