import Foundation

func runStorageChecks(capture: Data) throws {
    func expect(_ label: String, _ block: () throws -> Bool) throws { let value = try block(); check(value,label) }
    let fm = FileManager.default
    let testRoot = fm.temporaryDirectory.appendingPathComponent("green-meter-120-tests-"+UUID().uuidString)
    let records = testRoot.appendingPathComponent("records")
    let recorder = SessionRecorder(root:records)
    var config = MeterConfig(); config.webhook = "https://example.invalid/private-token-do-not-store"
    let began = Date(timeIntervalSince1970:1_792_470_000)
    try recorder.start(config:config,now:began)
    let folder = recorder.folder!
    let initial = try Data(contentsOf:folder.appendingPathComponent("session.json"))
    let initialJSON = try JSONSerialization.jsonObject(with:initial) as! [String:Any]
    check(initialJSON["source"] as? String == "device_tcp","recording provenance")
    check(!String(data:initial,encoding:.utf8)!.contains("private-token"),"webhook secrets excluded")
    try recorder.appendRaw(capture.prefix(1024),now:began)
    try recorder.checkpoint(now:began.addingTimeInterval(1))
    let partial = try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).first { $0.lastPathComponent.hasSuffix("raw.bin.part") }!
    try expect("raw persisted before stop") { try Data(contentsOf:partial) == capture.prefix(1024) }
    try recorder.summary(["power_w":NSNull(),"voltage_adc_rms":119.4,"calibrated":false],now:began.addingTimeInterval(1))
    try recorder.checkpoint(now:began.addingTimeInterval(61))
    try expect("minute segment closes") { try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).contains { $0.lastPathComponent == "000001-raw.bin" } }
    let mirror = DriveMirror(source:records)
    let offline = try mirror.sync(to:nil)
    check(offline.pending >= 3 && offline.copied == 0,"offline queue retained")
    let destination = testRoot.appendingPathComponent("mock-drive")
    check(tryValue { try mirror.sync(to:destination).copied } >= 3,"closed files copied")
    let copies = fm.enumerator(at:destination,includingPropertiesForKeys:nil)!.allObjects as! [URL]
    check(!copies.contains { $0.pathExtension == "part" || $0.lastPathComponent == "session.json" },"active manifest and partial files not copied")
    try expect("repeat sync idempotent") { try mirror.sync(to:destination).copied == 0 }
    try recorder.appendRaw(capture.dropFirst(1024),now:began.addingTimeInterval(62))
    try recorder.finish(reason:"test_finished",now:began.addingTimeInterval(63))
    let raw = try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasSuffix("raw.bin") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var joined = Data(); for file in raw { joined.append(try Data(contentsOf:file)) }
    check(joined == capture && recorder.savedBytes == 126906,"segments reconstruct exact real capture")
    let final = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("session.json"))) as! [String:Any]
    check(final["status"] as? String == "closed" && final["saved_raw_bytes"] as? Int == 126906,"closed manifest durable")
    try expect("final files copied") { try mirror.sync(to:destination).copied >= 4 }
    let mirrored = fm.enumerator(at:destination,includingPropertiesForKeys:nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix("raw.bin") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var mirrorBytes = Data(); for file in mirrored { mirrorBytes.append(try Data(contentsOf:file)) }
    check(mirrorBytes == capture,"mirrored exact stream")
    do { _ = try mirror.sync(to:records); check(false,"recursive target rejected") } catch { checks += 1 }
    let collisionRoot = testRoot.appendingPathComponent("collision-drive")
    let relative = String(raw[0].path.dropFirst(records.path.count+1))
    let conflict = collisionRoot.appendingPathComponent(relative)
    try fm.createDirectory(at:conflict.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data([1,2,3]).write(to:conflict)
    do { _ = try mirror.sync(to:collisionRoot);check(false,"collision pauses sync") } catch { checks += 1 }
    try expect("conflict unchanged") { try Data(contentsOf:conflict) == Data([1,2,3]) }
    try expect("source preserved") { try Data(contentsOf:raw[0]) == capture.prefix(1024) }
    let recoveryRoot = testRoot.appendingPathComponent("recovery")
    var orphan: SessionRecorder? = SessionRecorder(root:recoveryRoot)
    try orphan!.start(config:config,now:began)
    try orphan!.appendRaw(capture.prefix(600),now:began)
    let orphanFolder = orphan!.folder!; orphan = nil
    let recovery = SessionRecorder(root:recoveryRoot)
    try expect("crash recovery") { try recovery.recoverInterrupted() == 1 }
    let recovered = try JSONSerialization.jsonObject(with:Data(contentsOf:orphanFolder.appendingPathComponent("session.json"))) as! [String:Any]
    check(recovered["status"] as? String == "interrupted_recovered","interruption marked")
    let recoveredRaw = try fm.contentsOfDirectory(at:orphanFolder,includingPropertiesForKeys:nil).first { $0.lastPathComponent.hasSuffix("raw.bin") }!
    try expect("recovery no padding") { try Data(contentsOf:recoveredRaw) == capture.prefix(600) }
    try expect("recovery idempotent") { try recovery.recoverInterrupted() == 0 }
    let loop = SessionRecorder(root:testRoot.appendingPathComponent("loopback")); var loopConfig = config; loopConfig.host = "127.0.0.1"
    try loop.start(config:loopConfig,now:began);try loop.finish(reason:"test",now:began)
    let loopJSON = try JSONSerialization.jsonObject(with:Data(contentsOf:loop.folder!.appendingPathComponent("session.json"))) as! [String:Any]
    check(loopJSON["source"] as? String == "loopback_test_NOT_hardware","test isolation")
    var retry = ReconnectSchedule()
    check((0..<7).map { _ in retry.nextDelay() } == [1,2,4,8,16,30,30],"bounded backoff")
    retry.reset();check(retry.nextDelay() == 1,"retry reset")
    print("PASS FINAL: \(checks) checks including persistence, offline queue, recovery and mirror. Mock Drive only.")
    print("Test artifacts: \(testRoot.path)")
}

private func tryValue(_ block: () throws -> Int) -> Int { (try? block()) ?? -1 }
