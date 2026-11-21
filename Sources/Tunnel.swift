import Foundation

extension ServerModel {
    func startTunnel() {
        guard ownsLock, tunnelProcess == nil else{return}
        let path=option("playitPath")
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath:path) else{errorMessage="Choose your configured playit executable first.";return}
        let proc=Process()
        proc.executableURL=URL(fileURLWithPath:path)
        proc.arguments=[]
        proc.standardInput=FileHandle.nullDevice
        // Pair the agent separately; credentials and pairing links stay out of the Minecraft console.
        proc.standardOutput=FileHandle.nullDevice;proc.standardError=FileHandle.nullDevice
        proc.terminationHandler={ [weak self] child in Task { @MainActor in
            guard let self,self.tunnelProcess === child else{return}
            self.tunnelProcess=nil
            if child.terminationStatus != 0 && child.terminationReason != .uncaughtSignal {
                self.errorMessage="The tunnel agent exited. Check that your playit agent is paired and its Minecraft tunnel points to this Mac."
            }
        }}
        do {try proc.run();tunnelProcess=proc}catch{errorMessage=error.localizedDescription}
    }
    func stopTunnel(){
        if let child=tunnelProcess, child.isRunning {child.terminate()}
    }
}
