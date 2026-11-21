import Foundation

extension Downloads {
    func launchArguments(java: URL, vanilla: URL, profile: URL, settings: ServerSettings) async throws -> [String] {
        let options = settings.options
        let software = options["software"] ?? "Vanilla"
        var args = ["-Xms512M","-Xmx\(settings.memoryGB)G"]
        args += (options["javaFlags"] ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }
        switch software {
        case "Vanilla":
            args += ["-jar",vanilla.path]
        case "Fabric":
            let jar = profile.appendingPathComponent("lantern-fabric.jar")
            if !FileManager.default.fileExists(atPath: jar.path) {
                struct Loader: Decodable { struct Build: Decodable { let version: String; let stable: Bool }; let loader: Build }
                let base = "https://meta.fabricmc.net/v2/versions/"
                let builds = try JSONDecoder().decode([Loader].self, from: await fetch(base+"loader/"+settings.version))
                let installers = try JSONDecoder().decode([Loader.Build].self, from: await fetch(base+"installer"))
                guard let loader = builds.first(where: { $0.loader.stable })?.loader.version, let installer = installers.first(where: { $0.stable })?.version else { throw LanternError("No stable Fabric release for this version.") }
                let bytes = try await fetch(base+"loader/\(settings.version)/\(loader)/\(installer)/server/jar")
                guard bytes.starts(with: [0x50,0x4b]) else { throw LanternError("Fabric returned an invalid server file.") }
                try bytes.write(to: jar,options: .atomic)
            }
            args += ["-jar",jar.path]
        case "Paper":
            guard let name=options["PaperJar"],!name.isEmpty,name==URL(fileURLWithPath:name).lastPathComponent else { throw LanternError("Choose the matching Paper server JAR under Settings.") }
            let jar=profile.appendingPathComponent("server-software").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath:jar.path) else {throw LanternError("Choose the matching Paper JAR again.")}
            args += ["-jar",jar.path]
        case "NeoForge":
            guard let name=options["NeoForgeJar"],!name.isEmpty,name==URL(fileURLWithPath:name).lastPathComponent else { throw LanternError("Choose a NeoForge server installer for this Minecraft version.") }
            let installer=profile.appendingPathComponent("server-software").appendingPathComponent(name).path
            let marker=profile.appendingPathComponent(".lantern-neoforge")
            let digest=try ServerFiles.digest(URL(fileURLWithPath:installer), sha256:true)
            let argsRoot=profile.appendingPathComponent("libraries/net/neoforged/neoforge")
            let installName = URL(fileURLWithPath:installer).lastPathComponent
            guard installName.hasPrefix("neoforge-"), installName.hasSuffix("-installer.jar") else { throw LanternError("Choose the official neoforge-VERSION-installer.jar file.") }
            let build=String(installName.dropFirst(9).dropLast(14))
            let argFile=argsRoot.appendingPathComponent(build).appendingPathComponent("unix_args.txt")
            if (try? String(contentsOf:marker)) != digest || !FileManager.default.fileExists(atPath:argFile.path) {
                _ = try await Command.run(java.path,["-jar",installer,"--installServer",profile.path], directory:profile)
                guard FileManager.default.fileExists(atPath:argFile.path) else { throw LanternError("NeoForge did not create its server argument file.") }
                try digest.write(to:marker,atomically:true,encoding:.utf8)
            }
            args += ["@"+argFile.path]
        default: throw LanternError("Unknown server software.")
        }
        args += ["nogui"]
        args += (options["serverArgs"] ?? "").components(separatedBy:.newlines).filter { !$0.isEmpty }
        return args
    }

    private func fetch(_ url: String) async throws -> Data {
        guard let endpoint=URL(string:url) else { throw LanternError("Invalid version address.") }
        return try await data(from:endpoint)
    }
}

struct CatalogHit: Codable, Identifiable {
    let slug: String
    let title: String
    var id: String { slug }
}
struct CatalogRelease: Decodable,Identifiable {
    let id:String
    struct File: Decodable { let url: URL; let filename: String; let primary: Bool; let hashes: [String:String] }
    let files: [File]
    let version_number: String
}
enum Catalog {
    private static func request<T: Decodable>(_ path: String, _ queries: [String:String]) async throws -> T {
        var endpoint = URLComponents(string:"https://api.modrinth.com/v2/"+path)!
        endpoint.queryItems=queries.map { URLQueryItem(name:$0.key,value:$0.value) }
        var request=URLRequest(url:endpoint.url!)
        request.setValue("Foxfire-macOS/1.3",forHTTPHeaderField:"User-Agent")
        let (data,response)=try await URLSession.shared.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LanternError("Modrinth could not complete this request.") }
        return try JSONDecoder().decode(T.self,from:data)
    }
    static func json<T:Encodable>(_ value:T) throws -> String { String(decoding:try JSONEncoder().encode(value),as:UTF8.self) }
    static func search(_ query:String, version:String, loader:String) async throws -> [CatalogHit] {
        struct Response:Decodable { let hits:[CatalogHit] }
        let facets=[["versions:"+version],["categories:"+loader.lowercased()]]
        let results:Response=try await request("search",["query":query,"facets":try json(facets),"limit":"12"])
        return results.hits
    }
    static func releases(_ hit:CatalogHit, version:String, loader:String) async throws -> [CatalogRelease] {
        return try await request("project/"+hit.slug+"/version",["game_versions":try json([version]),"loaders":try json([loader.lowercased()])])
    }
    static func install(_ release:CatalogRelease,root:URL) async throws -> String {
        guard let file=release.files.first(where:{$0.primary}) ?? release.files.first,
              file.filename==URL(fileURLWithPath:file.filename).lastPathComponent,file.filename.hasSuffix(".jar"),file.url.scheme=="https",file.url.host=="cdn.modrinth.com",let hash=file.hashes["sha1"] else { throw LanternError("No compatible server JAR was found.") }
        let (temporary,response)=try await URLSession.shared.download(from:file.url)
        defer { try? FileManager.default.removeItem(at:temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,try ServerFiles.digest(temporary)==hash else { throw LanternError("The add-on failed verification.") }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:temporary,to:root.appendingPathComponent(file.filename))
        return file.filename
    }
}

extension Catalog {
    struct Candidate: Decodable {
        let project_id: String
        let version_number: String
    }
    static func newer(for jar:URL, version:String, loader:String) async throws -> (String,CatalogRelease.File,String)? {
        let originalHash=try ServerFiles.digest(jar)
        let known:Candidate=try await request("version_file/"+originalHash,["algorithm":"sha1"])
        let list:[CatalogRelease]=try await request("project/"+known.project_id+"/version",["game_versions":try json([version]),"loaders":try json([loader.lowercased()]),"version_type":"release"])
        guard let next=list.first,let file=next.files.first(where:{$0.primary}) ?? next.files.first,
              let hash=file.hashes["sha1"], hash != originalHash else{return nil}
        guard file.filename==URL(fileURLWithPath:file.filename).lastPathComponent,file.filename.hasSuffix(".jar"),
              file.url.scheme=="https",file.url.host=="cdn.modrinth.com" else{throw LanternError("Unsupported add-on download.")}
        return (known.version_number+" → "+next.version_number,file,originalHash)
    }
}
