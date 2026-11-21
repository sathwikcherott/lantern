import Foundation

extension ServerModel {
    func enterSleep() {
        guard !quitPending, state == .stopped else {return}
        let helper = Process()
        let output = Pipe()
        let script:URL
        #if LANTERN_QA
        script = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/sleeper.py")
        #else
        guard let resource=Bundle.main.url(forResource:"sleeper",withExtension:"py") else {errorMessage="Sleep helper is missing.";return}
        script=resource
        #endif
        let props=(try? String(contentsOf:selectedProfile.appendingPathComponent("server.properties"))) ?? ""
        let host=props.components(separatedBy:.newlines).first{$0.hasPrefix("server-ip=")}.map{String($0.dropFirst(10))} ?? ""
        helper.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        helper.arguments=["-B",script.path,host.isEmpty ? "0.0.0.0" : host,settings.port,settings.version,String(settings.maxPlayers),option("sleepMessage","Sleeping · join to wake up"),option("wakeMessage","Starting the server. Join again shortly.")]
        helper.standardOutput=output;helper.standardError=output
        helper.terminationHandler={ [weak self] child in
            let result=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
            Task { @MainActor in
                guard let self,self.sleepProcess === child else{return}
                self.sleepProcess=nil
                self.finishStopped()
                if self.quitPending {self.completeQuitIfNeeded();return}
                if self.wakeRequested || (child.terminationStatus==0 && result.contains("WAKE")) {
                    self.wakeRequested=false; self.start()
                } else if child.terminationStatus != 0 && child.terminationReason != .uncaughtSignal {
                    self.errorMessage="Could not keep the join address open. "+result
                }
            }
        }
        do {
            try helper.run()
            sleepProcess=helper;state = .sleeping
            settings.put("resume","true")
            activity=option("sleepMessage","Sleeping · join to wake up")
        } catch {errorMessage=error.localizedDescription}
    }
    func wakeServer() {
        guard let child=sleepProcess else{return}
        wakeRequested=true
        if child.isRunning {child.terminate()}
    }
}
