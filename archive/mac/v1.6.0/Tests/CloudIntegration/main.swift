import Foundation

final class MemoryKeys: CloudKeyStore {
    var values: [String:String] = [:]
    let lock = NSLock()
    func read(device: String) throws -> String? { lock.lock();defer{lock.unlock()};return values[device] }
    func save(_ key: String,device: String) throws { lock.lock();defer{lock.unlock()};values[device] = key }
}
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let base = URL(string:CommandLine.arguments[2])!
let endpoint = base.appendingPathComponent("api/ingest")
var checks = 0
func check(_ b: @autoclosure ()->Bool,_ note: String) { guard b() else { fatalError(note) };checks += 1 }
func waitFor(_ note: String,timeout: Double = 6,_ test: ()->Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !test() && Date() < end { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
    check(test(),note)
}
func control(_ mode: String) {
    var done = false
    URLSession.shared.dataTask(with:base.appendingPathComponent("mode/"+mode)){_,_,_ in done = true}.resume()
    waitFor("mock server control",{done})
}
func configure(_ sync: CloudSync,device: String = "meter-01",key: String = "gml_"+String(repeating:"a",count:64),enabled: Bool = true,valid: Bool = true) {
    var complete = false,error: String?
    sync.configure(device:device,key:key,enabled:enabled){error = $0;complete = true}
    waitFor("settings completion",{complete});check((error == nil) == valid,"settings validation")
}
let keys = MemoryKeys()
let sync = CloudSync(root:root,keys:keys,testEndpoint:endpoint)
waitFor("initialization",{sync.snapshot["ready"] as? Bool == true})
check(sync.snapshot["enabled"] as? Bool == false,"default cloud off")
configure(sync,key:"administrator-password",valid:false)
configure(sync)
var config = MeterConfig()
let v = (0..<128).map{200*sin(2*Double.pi*Double($0)/128)}
let i = (0..<128).map{100*sin(2*Double.pi*Double($0)/128)}
var window = LearningWindow()
for _ in 0..<5 { try window.append(v,i) }
let fixed = Date()
func record(_ index: Int,device: String = "meter-01",session: String = "test-session") throws -> CloudRecord {
    var w = LearningWindow();for _ in 0..<5 { try w.append(v,i) }
    return try CloudRecord.make(config:config,device:device,session:session,watts:200,window:w.take(now:fixed.addingTimeInterval(Double(index)))!)
}
let one = try record(0)
let encoded = try JSONEncoder().encode(one)
let object = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
let row = object["reading"] as! [String:Any]
check(row["energy_kwh"] is NSNull && row["quality"] as? String == "reference","no unverified meter energy")
check(one.profile.contains("|6400.0|128") && one.window.values.count == 12,"native model compatibility")
var loop = config;loop.host = "127.0.0.1"
do { _ = try CloudRecord.make(config:loop,device:"meter-01",session:"t",watts:200,window:window.take(now:fixed)!);fatalError("loopback accepted") } catch { checks += 1 }
do { _ = try CloudRecord.make(config:config,device:"meter-01",session:"t",watts:-1,window:LearningFeatureWindow(time:fixed,values:one.window.values,frames:5,voltagePreviewADC:v,currentPreviewADC:i));fatalError("negative accepted") } catch { checks += 1 }

for j in 0..<12 { sync.enqueue(try record(j)) }
waitFor("durable queue 12",{sync.snapshot["pending"] as? Int == 12})
let restored = CloudSync(root:root,keys:keys,testEndpoint:endpoint)
waitFor("restore pending",{restored.snapshot["pending"] as? Int == 12})
let configFile = root.appendingPathComponent("website-sync/settings.json")
let configText = String(data:try Data(contentsOf:configFile),encoding:.utf8)!
check(!configText.contains("gml_"),"no secret in settings")

control("503");sync.retryNow()
waitFor("network failure retained",{(sync.snapshot["message"] as? String ?? "").contains("重试")})
check(sync.snapshot["pending"] as? Int == 12,"503 cannot discard")
control("wrong-ack");sync.retryNow()
waitFor("invalid ack retained",{(sync.snapshot["message"] as? String ?? "").contains("回执不完整")})
check(sync.snapshot["pending"] as? Int == 12,"incomplete ack cannot discard")
control("redirect");sync.retryNow()
waitFor("redirect rejected",{sync.snapshot["blocked"] as? Bool == true})
check(sync.snapshot["pending"] as? Int == 12,"redirect cannot discard")
control("401");sync.retryNow()
waitFor("bad key visible",{(sync.snapshot["message"] as? String ?? "").contains("密钥无效")})
check(sync.snapshot["pending"] as? Int == 12,"401 cannot discard")
control("ok");sync.retryNow()
waitFor("batch 10 acknowledged",{sync.snapshot["pending"] as? Int == 2})
sync.retryNow();waitFor("batch 2 acknowledged",{sync.snapshot["pending"] as? Int == 0})
check(!(sync.snapshot["lastSuccess"] as? String ?? "").isEmpty,"last ack recorded")
// Replaying identical timestamps is safe: the mock returns duplicate acknowledgments.
sync.enqueue(try record(0));waitFor("duplicate queued",{sync.snapshot["pending"] as? Int == 1})
sync.retryNow();waitFor("duplicate acknowledged",{sync.snapshot["pending"] as? Int == 0})
sync.enqueue(try record(14));waitFor("old device queued",{sync.snapshot["pending"] as? Int == 1})
configure(sync,device:"meter-02")
check(sync.snapshot["otherDevicePending"] as? Int == 1,"device change isolates backlog")
configure(sync,device:"meter-01",key:"",enabled:false)
sync.retryNow();RunLoop.main.run(until:Date().addingTimeInterval(0.15))
check(sync.snapshot["pending"] as? Int == 1,"paused backlog retained")
configure(sync,key:"")
waitFor("reenable drains",{sync.snapshot["pending"] as? Int == 0})
// Native controller rejects demo, file, loopback and disconnected frames before queueing.
let nativeSync = CloudSync(root:root.appendingPathComponent("native"),keys:keys,testEndpoint:endpoint)
let controller = MeterController(storageRoot:root.appendingPathComponent("native"),enableDrive:false,cloudSync:nativeSync)
waitFor("native init",{controller.cloud.snapshot["ready"] as? Bool == true})
configure(nativeSync)
controller.mode = "live";controller.connected = true
check(controller.canSyncCloudFrames,"real collection gate reachable when enabled")
controller.mode = "live";controller.connected = true;controller.config.host = "127.0.0.1"
check(!controller.canSyncCloudFrames,"native loopback excluded")
controller.mode = "demo";check(!controller.canSyncCloudFrames,"native demo excluded")
controller.mode = "file";check(!controller.canSyncCloudFrames,"native replay excluded")
controller.config.host = "192.168.1.2";controller.mode = "live";controller.connected = false
check(!controller.canSyncCloudFrames,"native disconnected excluded")
controller.timer?.invalidate()
controller.connected = true
var frame = MeterFrame();frame.voltage = v;frame.current = i;frame.rawSamples = true
for _ in 0..<5 { controller.consume(frame) }
controller.cloudLastTick = Date().addingTimeInterval(-1.1);controller.cloudTick()
waitFor("native frame-to-disk pipeline",{nativeSync.snapshot["pending"] as? Int == 1})
let nativeFiles = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("native/website-sync"),includingPropertiesForKeys:nil).filter{$0.pathExtension == "pending"}
let nativeRecord = try JSONDecoder().decode(CloudRecord.self,from:Data(contentsOf:nativeFiles[0]))
let expected = try referencePower(v,i,config:config)
check(abs(nativeRecord.reading.estimated_power_w-expected.powerW)<0.001,"native reference watts reach queue unchanged")
nativeSync.retryNow();waitFor("native frame-to-mock acknowledgment",{nativeSync.snapshot["pending"] as? Int == 0})
let firstSession = controller.cloudSession
controller.resetCloudWindow();check(firstSession != controller.cloudSession,"gaps split cloud sessions")
let small = CloudSync(root:root.appendingPathComponent("quota"),keys:keys,quota:1,testEndpoint:endpoint)
waitFor("quota init",{small.snapshot["ready"] as? Bool == true});configure(small)
small.enqueue(try record(0))
waitFor("quota visible",{(small.snapshot["message"] as? String ?? "").contains("上限")})
check(small.snapshot["pending"] as? Int == 0,"quota does not falsely claim saved")
let report:[String:Any] = ["passed":true,"checks":checks,"source":"local_synthetic_cloud_sync_test_NOT_hardware","hardware_verified":false,"production_data_uploaded":false]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
print("PASS: \(checks) website-sync checks; synthetic localhost only, no production upload.")
