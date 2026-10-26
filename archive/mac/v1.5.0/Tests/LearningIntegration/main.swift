import Foundation

func requireLearning(_ yes: Bool, _ message: String) { if !yes { fatalError(message) } }
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let ready = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("ready.json"))) as! [String:Int]
let controller = MeterController(storageRoot:root.appendingPathComponent("records"),enableDrive:false)
let appliance = try controller.learner.add(name:"模拟台灯-仅本机测试",loopback:true)
let body: [String:Any] = ["applianceID":appliance.id,"state":"running"]
do { try controller.beginLearning(body);fatalError("learning allowed without connection") } catch {}
var cfg = MeterConfig();cfg.host = "127.0.0.1";cfg.port = ready["port"]!
try controller.start(cfg)
RunLoop.main.run(until:Date().addingTimeInterval(2.5))
requireLearning(controller.connected && controller.decoder.goodFrames > 50,"no synthetic socket frames")
try controller.beginLearning(body)
do { try controller.sendDeviceCommand(.relayOn,encoding:.singleByte);fatalError("control sent during capture") } catch {}
RunLoop.main.run(until:Date().addingTimeInterval(22))
if controller.learningCapture != nil || controller.learner.captures.count != 1 {
    print("CAPTURE DEBUG", controller.learningCapture?.windows.count ?? -1, controller.learningCapture.map{Date().timeIntervalSince($0.startedAt)} ?? -1, controller.learningStatus, controller.learningSignalError, controller.logLines)
    fflush(stdout)
}
requireLearning(controller.learningCapture == nil && controller.learner.captures.count == 1,"20-second native capture not saved")
let observed = controller.learner.captures[0]
try observed.validate()
requireLearning(observed.source == "loopback_test_NOT_hardware" && observed.windows.count >= 16,"wrong source or incomplete segment")

// Extra independent fixture segments are explicit synthetic data in this test root only.
func fixture(state: ApplianceState, index: Int) throws -> LearningCapture {
    let v = (0..<128).map{Double(round(160*sin(2*Double.pi*Double($0)/128)+5))}
    let amp = state == .off ? 0.0 : 30.0
    let i = (0..<128).map{Double(round(amp*sin(2*Double.pi*Double($0)/128)+18))}
    let f = try applianceFeatures(v,i),began = Date(timeIntervalSince1970:1000+Double(index)*30)
    return LearningCapture(id:UUID().uuidString,label:LearningLabel(applianceID:appliance.id,applianceName:appliance.name,state:state),profile:learningProfile(cfg),source:"loopback_test_NOT_hardware",featureVersion:learningFeatureVersion,startedAt:began,endedAt:began.addingTimeInterval(20),acquisitionSession:"synthetic_fixture_NOT_hardware",rawByteStart:0,rawByteEnd:518000,windows:(1...20).map{LearningFeatureWindow(time:began.addingTimeInterval(Double($0)),values:f,frames:50,voltagePreviewADC:v,currentPreviewADC:i)})
}
for j in 0..<3 { try controller.learner.saveCapture(fixture(state:.off,index:j),loopback:true) }
for j in 3..<5 { try controller.learner.saveCapture(fixture(state:.running,index:j),loopback:true) }
try controller.handleLearning("learningTrain",body:[:])
requireLearning(controller.learningCachedModel?.validation?.passed == true,"native model training failed")
RunLoop.main.run(until:Date().addingTimeInterval(4.2))
requireLearning(controller.learningMatch?.appliance == appliance.name && controller.learningStreak >= 3,"live lamp match not stabilized")
let running = controller.learningMatch!
try jsonData(["amplitude":0]).write(to:root.appendingPathComponent("control.json"),options:.atomic)
RunLoop.main.run(until:Date().addingTimeInterval(4.2))
requireLearning(controller.learningMatch?.state == "关闭" && controller.learningMatch?.appliance == nil,"off baseline incorrectly identified appliance")
try jsonData(["amplitude":2000,"third":0.9,"phase":1.3]).write(to:root.appendingPathComponent("control.json"),options:.atomic)
RunLoop.main.run(until:Date().addingTimeInterval(2.2))
requireLearning(controller.learningMatch?.key == nil,"unseen waveform accepted")
let before = controller.learner.captures.count
try controller.beginLearning(body)
RunLoop.main.run(until:Date().addingTimeInterval(0.5))
controller.disconnect()
requireLearning(controller.learningCapture == nil && controller.learner.captures.count == before && controller.learningMatch == nil,"partial disconnected capture leaked into training")
controller.mode = "file"
do { try controller.beginLearning(body);fatalError("historical replay allowed for live learning") } catch {}
let restored = ApplianceLearningStore(root:root.appendingPathComponent("records"))
requireLearning(restored.currentModel(profile:learningProfile(cfg),source:"loopback_test_NOT_hardware") != nil,"model did not restore")
requireLearning(restored.currentModel(profile:learningProfile(MeterConfig()),source:"device_user_label") == nil,"mock model leaked into production")
let report: [String:Any] = ["source":"loopback_synthetic_NOT_hardware","native_capture_windows":observed.windows.count,"native_capture_seconds":observed.endedAt.timeIntervalSince(observed.startedAt),"synthetic_training_segments":restored.captures.count,"validation":controller.learningLastValidation.map{controller.learningObject($0)} ?? NSNull(),"known_match":controller.learningObject(running),"off_name_suppressed":true,"unknown_rejected":true,"partial_capture_rejected":true,"replay_learning_rejected":true,"production_isolated":true,"model_restored":true,"frames":controller.decoder.goodFrames,"saved_raw_bytes":controller.recorder.savedBytes,"calibrated":controller.config.calibrated,"energy_kwh":NSNull(),"notes":"本机 TCP 与人工合成样本的功能验证；不代表真实电器识别准确率。未连接真实插座，未切换 Wi-Fi。"]
try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("result.json"))
print("PASS: native capture → disk → grouped training → live match / off / unknown → restart. Synthetic loopback only.")
