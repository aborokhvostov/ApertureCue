#if os(macOS)
import Foundation
import QuartzCore
import Darwin
import MappingCore

/// Own generated files and own spawned processes only. A SIGKILL check is
/// separate from editor callbacks, manual GUI operation and power-loss testing.
@MainActor enum MediaDurabilitySelfTest {
    private struct Failure:LocalizedError {let message:String;var errorDescription:String? {message}}
    private struct Owner:Codable {
        let format:String
        let token:UUID
        let parentPID:Int32
    }
    private static let ownerName=".aperturecue-durability-owner.json"
    private static let prefix="ApertureCueDurability-"
    private static func expect(_ condition:@autoclosure()throws->Bool,_ message:String)throws {
        if try !condition() {throw Failure(message:message)}
    }
    private static func pump(_ seconds:Double,_ condition:()->Bool)->Bool {
        let end=CACurrentMediaTime()+seconds
        repeat {
            if condition() {return true}
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))
        } while CACurrentMediaTime()<end
        return condition()
    }
    private static func owner(at folder:URL,token:UUID)throws->Owner {
        let fm=FileManager.default,canonical=folder.resolvingSymlinksInPath().standardizedFileURL
        let temporary=fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        try expect(canonical==folder.standardizedFileURL && canonical.deletingLastPathComponent()==temporary,
                   "Writer requires a direct canonical temporary fixture directory")
        try expect(canonical.lastPathComponent.hasPrefix(prefix) && UUID(uuidString:String(canonical.lastPathComponent.dropFirst(prefix.count))) != nil,
                   "Writer fixture directory does not have the owned UUID prefix")
        let marker=canonical.appendingPathComponent(ownerName)
        let attributes=try fm.attributesOfItem(atPath:marker.path)
        try expect(attributes[.type] as? FileAttributeType == .typeRegular && ((attributes[.size] as? NSNumber)?.intValue ?? Int.max)<=4096,
                   "Writer ownership marker is absent, nonregular or oversized")
        let value=try JSONDecoder().decode(Owner.self,from:Data(contentsOf:marker))
        try expect(value.format=="ApertureCue isolated durability fixture" && value.token==token && value.parentPID>1 && value.parentPID==getppid(),
                   "Writer token or immediate parent process does not own the fixture")
        return value
    }
    static func writer(arguments:[String])->Int32 {
        do {
            var args=arguments
            if let flag=args.firstIndex(of:"--durability-writer") {args=Array(args.dropFirst(flag+1))}
            try expect(args.count==2,"Writer requires its fixture directory and ownership token")
            guard let token=UUID(uuidString:args[1]) else {throw Failure(message:"Writer ownership token is invalid")}
            let folder=URL(fileURLWithPath:args[0],isDirectory:true).standardizedFileURL
            _=try owner(at:folder,token:token)
            let saved=folder.appendingPathComponent("project.aperturecue.json")
            let revision=try ProjectStore.loadWithRecoveryBaseline(from:saved)
            try expect(revision.project.name=="Durability saved fixture" && revision.project.assets.isEmpty && revision.project.surfaces.count==1,
                       "Writer may mutate only the original generated fixture document")
            var edited=revision.project;edited.name="Durability recovered fixture";edited.surfaces[0].brightness=0.42
            try ProjectStore.saveRecovery(edited,for:saved,baseline:revision.baseline)
            try expect(try ProjectStore.loadRecovery(for:saved)==edited,"Writer snapshot did not validate before the checkpoint")
            let ready:[String:Any]=["format":"ApertureCue durability ready","token":token.uuidString,"writerPID":getpid(),"sourceSHA256":revision.baseline.sourceSHA256]
            let data=try JSONSerialization.data(withJSONObject:ready,options:[.sortedKeys])
            try expect(data.count<4096,"Writer checkpoint exceeded its bounded marker size")
            try data.write(to:folder.appendingPathComponent("writer-ready.json"),options:.atomic)
            // Parent kills this exact Process after the ready marker. A timeout
            // exit cannot be counted as successful forced-termination evidence.
            let deadline=CACurrentMediaTime()+120
            while CACurrentMediaTime()<deadline {RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))}
            return 3
        } catch {
            fputs("Durability writer refused or failed: \(error.localizedDescription)\n",stderr)
            return 2
        }
    }
    static func run()->Int32 {
        let started=CACurrentMediaTime(),fm=FileManager.default
        let reportDirectory=URL(fileURLWithPath:fm.currentDirectoryPath,isDirectory:true).appendingPathComponent("artifacts/local/durability",isDirectory:true)
        let token=UUID(),folder=fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(prefix+UUID().uuidString,isDirectory:true)
        var processes:[Process]=[],checks:[String]=[],detail:[String:Any]=[:]
        func pass(_ name:String) {checks.append(name);print("PASS durability: "+name)}
        func report(_ passed:Bool,_ failure:String?=nil) {
            var data:[String:Any]=["schemaVersion":1,"timestampUTC":ISO8601DateFormatter().string(from:Date()),"platform":ProcessInfo.processInfo.operatingSystemVersionString,"passed":passed,"checkCount":checks.count,"checks":checks,"elapsedSeconds":CACurrentMediaTime()-started,"hardwareVerification":false,"scope":"Original isolated temporary project; real spawned writer, complete atomic recovery checkpoint, SIGKILL, fresh file/model verification and stale/corrupt rejection","details":detail,"limitations":"Not a power-loss, disk-full, filesystem-corruption or simultaneous-adversarial-writer test. No user project, external application or hardware was accessed."]
            if let failure {data["failure"]=failure}
            do {try fm.createDirectory(at:reportDirectory,withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:reportDirectory.appendingPathComponent("report.json"),options:.atomic)} catch {fputs("Durability report failed: \(error)\n",stderr)}
        }
        defer {
            for process in processes where process.isRunning {
                if process.processIdentifier>1 {_=Darwin.kill(process.processIdentifier,SIGKILL)}
                _=pump(3,{!process.isRunning})
            }
            if processes.allSatisfy({!$0.isRunning}) {try? fm.removeItem(at:folder)}
        }
        do {
            try fm.createDirectory(at:folder,withIntermediateDirectories:false)
            let marker=Owner(format:"ApertureCue isolated durability fixture",token:token,parentPID:getpid())
            try JSONEncoder().encode(marker).write(to:folder.appendingPathComponent(ownerName),options:.atomic)
            let url=folder.appendingPathComponent("project.aperturecue.json")
            let original=Project(name:"Durability saved fixture",surfaces:[Surface(name:"Original procedural layer")])
            let baseline=try ProjectStore.saveWithRecoveryBaseline(original,to:url),savedBytes=try Data(contentsOf:url)
            let executable=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
            func spawn(_ suppliedToken:UUID)throws->Process {
                let process=Process();process.executableURL=executable
                process.arguments=["--durability-writer",folder.path,suppliedToken.uuidString]
                process.currentDirectoryURL=folder;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                try process.run();processes.append(process);return process
            }
            let refused=try spawn(UUID())
            try expect(pump(10,{!refused.isRunning}),"Invalid-token writer did not exit within its bound")
            refused.waitUntilExit()
            try expect(refused.terminationReason == .exit && refused.terminationStatus==2,"Invalid-token writer was not refused")
            try expect(try Data(contentsOf:url)==savedBytes && ProjectStore.recoveryStatus(for:url).state == .missing,"Refused writer changed the saved project or created recovery")
            pass("writer refuses an invalid ownership token before mutating the generated fixture")

            let child=try spawn(token),readyURL=folder.appendingPathComponent("writer-ready.json")
            try expect(pump(30,{fm.fileExists(atPath:readyURL.path) || !child.isRunning}),"Recovery writer checkpoint timed out")
            try expect(child.isRunning && fm.fileExists(atPath:readyURL.path),"Recovery writer exited before announcing its atomic snapshot checkpoint")
            let readyData=try Data(contentsOf:readyURL);try expect(readyData.count<4096,"Writer ready marker is oversized")
            let ready=try JSONSerialization.jsonObject(with:readyData) as? [String:Any]
            try expect(ready?["format"] as? String == "ApertureCue durability ready" && ready?["token"] as? String == token.uuidString && (ready?["writerPID"] as? NSNumber)?.int32Value==child.processIdentifier,
                       "Writer checkpoint ownership does not match the spawned process")
            try expect(child.processIdentifier>1 && Darwin.kill(child.processIdentifier,SIGKILL)==0,"Failed to SIGKILL the owned writer process")
            try expect(pump(5,{!child.isRunning}),"SIGKILL writer did not terminate within its bound")
            child.waitUntilExit()
            try expect(child.terminationReason == .uncaughtSignal && child.terminationStatus==SIGKILL,"Writer did not terminate by signal 9")
            detail["writerTerminationReason"]="uncaughtSignal";detail["writerTerminationStatus"]=child.terminationStatus
            pass("the exact spawned writer is forcibly terminated by SIGKILL after its complete atomic recovery checkpoint")

            let reopened=try ProjectStore.loadWithRecoveryBaseline(from:url),recovered=try ProjectStore.loadRecovery(for:url)
            try expect(try Data(contentsOf:url)==savedBytes && reopened.project==original && reopened.baseline==baseline,"Forced termination altered the saved project bytes or revision")
            try expect(recovered.name=="Durability recovered fixture" && recovered.surfaces[0].brightness==0.42 && recovered.surfaces[0].id==original.surfaces[0].id,
                       "Fresh recovery did not retain the writer's distinct model and UUID")
            detail["savedBytesUnchanged"]=true;detail["projectSchema"]=recovered.version
            pass("fresh reads retain the saved bytes and recover the distinct unsaved model after forced termination")

            let sidecar=ProjectStore.recoveryURL(for:url),snapshot=try Data(contentsOf:sidecar)
            var external=original;external.name="New external saved revision";try ProjectStore.save(external,to:url)
            let externalBytes=try Data(contentsOf:url)
            try expect(ProjectStore.recoveryStatus(for:url).state == .stale,"External saved revision did not invalidate recovery")
            var rejected=false;do {_=try ProjectStore.loadRecovery(for:url)} catch {rejected=true}
            try expect(rejected && (try Data(contentsOf:sidecar))==snapshot && (try Data(contentsOf:url))==externalBytes,"Stale recovery was loaded, deleted or overwrote the external saved revision")
            pass("external replacement makes the old snapshot stale without changing either file")

            let corrupt=Data("{original deliberately truncated recovery fixture".utf8);try corrupt.write(to:sidecar,options:.atomic)
            try expect(ProjectStore.recoveryStatus(for:url).state == .invalid,"Truncated recovery was not diagnosed")
            let current=try ProjectStore.captureRecoveryBaseline(for:url)
            rejected=false;do {try ProjectStore.saveRecovery(external,for:url,baseline:current)} catch {rejected=true}
            try expect(rejected && (try Data(contentsOf:sidecar))==corrupt && (try Data(contentsOf:url))==externalBytes,"Autosave replaced corrupt recovery or changed saved data")
            pass("corrupt recovery is preserved and autosave refuses to overwrite it")
            report(true);return 0
        } catch {report(false,error.localizedDescription);fputs("FAIL durability: \(error.localizedDescription)\n",stderr);return 1}
    }
}
#endif
