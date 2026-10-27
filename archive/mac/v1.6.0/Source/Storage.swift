import Foundation
import CryptoKit

func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject:value, options:[.sortedKeys])
}
func digestFile(_ url: URL) throws -> String {
    let input = try FileHandle(forReadingFrom:url); defer { try? input.close() }
    var digest = SHA256()
    while let data = try input.read(upToCount:65536), !data.isEmpty { digest.update(data:data) }
    return digest.finalize().map { String(format:"%02x",$0) }.joined()
}

/// Immutable closed segments can be copied to Drive; active .part files stay local.
/// No raw samples are synthesized or discarded by the recorder.
final class SessionRecorder {
    let root: URL
    private(set) var folder: URL?
    private(set) var session = ""
    private(set) var savedBytes = 0
    private(set) var segment = 0
    private(set) var active = false
    private var handles: [String:FileHandle] = [:]
    private var started = Date()
    private var segmentStarted = Date()
    private var segmentBytes = 0
    private var metadata: [String:Any] = [:]
    private var segments: [[String:Any]] = []

    init(root: URL) { self.root = root }
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Codex/绿电实验室采集数据", isDirectory:true)
    }
    func start(config: MeterConfig, now: Date = Date()) throws {
        guard !active else { throw MeterError.invalid("已有自动保存会话，请先结束") }
        let fm = FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        if let free = (try? fm.attributesOfFileSystem(forPath:root.path)[.systemFreeSize]) as? NSNumber,
           free.int64Value < 268_435_456 { throw MeterError.invalid("可用磁盘不足 256 MB，暂不开始连续采集") }
        session = UUID().uuidString
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"; date.timeZone = TimeZone(identifier:"Asia/Shanghai")
        let loopback = config.transport == "client" ? config.host.hasPrefix("127.") : config.bindIP.hasPrefix("127.")
        let bucket = loopback ? "回环测试" : "真实采集"
        folder = root.appendingPathComponent(bucket).appendingPathComponent(date.string(from:now)).appendingPathComponent(session)
        try fm.createDirectory(at:folder!,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        metadata = ["schema":2,"app_version":"1.4.0","session_id":session,
            "source":loopback ? "loopback_test_NOT_hardware" : "device_tcp",
            "started_at":ISO8601DateFormatter().string(from:now),"host":config.host,"port":config.port,
            "protocol":config.protocolName,"sample_rate_configured":config.sampleRate,
            "sample_rate_verified_by_operator":config.calibrated,"calibrated":config.calibrated,
            "voltage_scale":config.voltageScale,"current_scale":config.currentScale,
            "voltage_offset_adc":config.voltageOffset,"current_offset_adc":config.currentOffset,
            "current_sign":config.currentSign,"status":"recording"]
        started = now; segmentStarted = now; savedBytes = 0; segment = 0; segmentBytes = 0; segments = []
        try jsonData(metadata).write(to:folder!.appendingPathComponent("session.json"),options:.atomic)
        active = true
        try event("session_started",details:["notes":"完整原始字节自动落盘；ADC 与物理单位分开；不补算断连时段"],now:now)
    }
    private func output(_ name: String, now: Date) throws -> FileHandle {
        guard active, let folder = folder else { throw MeterError.invalid("没有自动保存会话") }
        if let handle = handles[name] { return handle }
        if handles.isEmpty { segment += 1; segmentStarted = now; segmentBytes = 0 }
        let url = folder.appendingPathComponent(String(format:"%06d-",segment)+name+".part")
        guard !FileManager.default.fileExists(atPath:url.path),
              FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else {
            throw MeterError.invalid("无法创建采集文件，已保留现有记录")
        }
        let handle = try FileHandle(forWritingTo:url); handles[name] = handle; return handle
    }
    func appendRaw(_ data: Data, now: Date = Date()) throws {
        guard active else { return }
        try output("raw.bin",now:now).write(contentsOf:data)
        savedBytes += data.count; segmentBytes += data.count
        if segmentBytes >= 1_048_576 { try rotate(now:now,reason:"size_limit") }
    }
    func summary(_ value: [String:Any], now: Date = Date()) throws { try line(value,name:"summary.jsonl",now:now) }
    func event(_ name: String, details: [String:Any] = [:], now: Date = Date()) throws {
        var row = details; row["event"] = name; row["timestamp"] = ISO8601DateFormatter().string(from:now)
        try line(row,name:"events.jsonl",now:now)
    }
    private func line(_ value: [String:Any], name: String, now: Date) throws {
        guard active else { return }
        var data = try jsonData(value); data.append(10)
        try output(name,now:now).write(contentsOf:data)
    }
    func checkpoint(now: Date = Date()) throws {
        guard active else { return }
        for h in handles.values { try h.synchronize() }
        if !handles.isEmpty, now.timeIntervalSince(segmentStarted) >= 60 { try rotate(now:now,reason:"periodic") }
    }
    private func rotate(now: Date, reason: String) throws {
        guard let folder = folder, !handles.isEmpty else { return }
        let names = handles.keys.sorted()
        for name in names { try handles[name]?.synchronize(); try handles[name]?.close() }
        handles.removeAll()
        var files: [[String:Any]] = []
        for name in names {
            let filename = String(format:"%06d-",segment)+name
            let temporary = folder.appendingPathComponent(filename+".part"), final = folder.appendingPathComponent(filename)
            try FileManager.default.moveItem(at:temporary,to:final)
            files.append(["name":filename,"bytes":(try final.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0,"sha256":try digestFile(final)])
        }
        let snapshot: [String:Any] = ["session_id":session,"segment":segment,"reason":reason,
            "opened_at":ISO8601DateFormatter().string(from:segmentStarted),"closed_at":ISO8601DateFormatter().string(from:now),"files":files]
        try jsonData(snapshot).write(to:folder.appendingPathComponent(String(format:"segment-%06d.json",segment)),options:.atomic)
        segments.append(snapshot)
        metadata["saved_raw_bytes"] = savedBytes; metadata["closed_segments"] = segments.count
        try jsonData(metadata).write(to:folder.appendingPathComponent("session.json"),options:.atomic)
    }
    func finish(reason: String, now: Date = Date()) throws {
        guard active, let folder = folder else { return }
        try event("session_finished",details:["reason":reason],now:now)
        try rotate(now:now,reason:reason)
        metadata["status"] = "closed"; metadata["ended_at"] = ISO8601DateFormatter().string(from:now)
        metadata["saved_raw_bytes"] = savedBytes
        try jsonData(metadata).write(to:folder.appendingPathComponent("session.json"),options:.atomic)
        active = false
    }
    /// Recover only this app's unfinished sessions. Nothing is deleted or padded.
    func recoverInterrupted() throws -> Int {
        guard !active else { return 0 }
        let fm = FileManager.default
        guard let walker = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let url as URL in walker where url.lastPathComponent == "session.json" {
            guard var value = (try? JSONSerialization.jsonObject(with:Data(contentsOf:url))) as? [String:Any],
                  value["status"] as? String == "recording",value["schema"] as? Int == 2 else { continue }
            for part in try fm.contentsOfDirectory(at:url.deletingLastPathComponent(),includingPropertiesForKeys:nil) where part.pathExtension == "part" {
                let destination = part.deletingPathExtension()
                guard !fm.fileExists(atPath:destination.path) else { continue }
                try fm.moveItem(at:part,to:destination)
            }
            value["status"] = "interrupted_recovered"
            value["recovery_note"] = "上次未正常结束。保留已写入的全部字节；末尾可能为不完整帧或 JSON 行，不能视作完整测量。"
            try jsonData(value).write(to:url,options:.atomic); count += 1
        }
        return count
    }
}

struct MirrorResult {
    var copied = 0
    var pending = 0
    var message = "等待 Google Drive 桌面端"
}

/// Writes immutable files into the user's official Drive folder. Copy != server confirmation.
/// Google Drive for desktop owns authentication, offline queueing and network transfer.
final class DriveMirror {
    let source: URL
    private let ledgerURL: URL
    init(source: URL) { self.source = source; ledgerURL = source.appendingPathComponent("drive-handoff.json") }
    static func detectedDestination() -> URL? {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let folders = try? FileManager.default.contentsOfDirectory(at:storage,includingPropertiesForKeys:nil) else { return nil }
        let matches = folders.filter { $0.lastPathComponent == "GoogleDrive-ziben.mac@gmail.com" }
        guard matches.count == 1 else { return nil }
        for name in ["My Drive","我的云端硬盘","我的雲端硬碟"] {
            let drive = matches[0].appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:drive.path) { return drive.appendingPathComponent("绿电实验室/采集数据") }
        }
        return nil
    }
    func sync(to target: URL?) throws -> MirrorResult {
        let fm = FileManager.default
        var ledger = ((try? Data(contentsOf:ledgerURL)).flatMap { try? JSONDecoder().decode([String:String].self,from:$0) }) ?? [:]
        var candidates: [URL] = []
        for bucket in ["真实采集","回环测试"] {
            guard let walker = fm.enumerator(at:source.appendingPathComponent(bucket),includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else { continue }
            for case let file as URL in walker {
                guard ["bin","json","jsonl","csv"].contains(file.pathExtension),
                      (try? file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true else { continue }
                if file.lastPathComponent == "session.json",
                   let value = (try? JSONSerialization.jsonObject(with:Data(contentsOf:file))) as? [String:Any],value["status"] as? String == "recording" { continue }
                candidates.append(file)
            }
        }
        var result = MirrorResult()
        guard let target = target else { result.pending = candidates.count; return result }
        let destinationPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath+"/") else {
            throw MeterError.invalid("同步目标不能位于本地采集目录内")
        }
        // Do not create a fake CloudStorage mount when Drive is disconnected.
        if target.path.contains("/Library/CloudStorage/GoogleDrive-") {
            let components = target.pathComponents
            if let index = components.firstIndex(where:{$0.hasPrefix("GoogleDrive-")}) {
                let mount = NSString.path(withComponents:Array(components.prefix(index+2)))
                guard fm.fileExists(atPath:mount) else { result.pending = candidates.count; result.message = "Drive 未挂载，已保留本地待同步记录"; return result }
            }
        }
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        for file in candidates.sorted(by:{$0.path<$1.path}) {
            let relative = String(file.path.dropFirst(source.path.count+1))
            let hash = try digestFile(file), key = target.path+"/"+relative
            let destination = target.appendingPathComponent(relative)
            if ledger[key] == hash, fm.fileExists(atPath:destination.path) { continue }
            try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            if fm.fileExists(atPath:destination.path) {
                guard try digestFile(destination) == hash else { throw MeterError.invalid("Drive 目录中存在同名不同内容文件，已保留本地数据并暂停复制") }
            } else {
                let temporary = destination.deletingLastPathComponent().appendingPathComponent("."+destination.lastPathComponent+".copying-"+UUID().uuidString)
                try fm.copyItem(at:file,to:temporary)
                guard try digestFile(temporary) == hash else { throw MeterError.invalid("Drive 目录副本核对失败，本地原件保留") }
                try fm.moveItem(at:temporary,to:destination)
            }
            ledger[key] = hash; result.copied += 1
            try JSONEncoder().encode(ledger).write(to:ledgerURL,options:.atomic)
        }
        result.message = candidates.isEmpty ? "Drive 同步目录已就绪，等待新采集文件" : "已交给 Drive 同步；云端进度以 Drive 客户端为准"
        return result
    }
}

struct ReconnectSchedule {
    private(set) var attempt = 0
    mutating func nextDelay() -> Double { let delay = min(30.0,pow(2.0,Double(min(attempt,5)))); attempt += 1; return delay }
    mutating func reset() { attempt = 0 }
}
