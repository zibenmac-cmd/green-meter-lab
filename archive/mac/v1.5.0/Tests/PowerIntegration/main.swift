import Foundation
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let ready = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("ready.json"))) as! [String:Int]
let controller = MeterController(storageRoot:root.appendingPathComponent("records"),enableDrive:false)
var cfg = MeterConfig();cfg.host = "127.0.0.1";cfg.port = ready["port"]!;cfg.voltageOffset = 5;cfg.currentOffset = 18
try controller.start(cfg)
RunLoop.main.run(until:Date().addingTimeInterval(2.4))
func require(_ condition:Bool,_ note:String) { if !condition { fatalError(note) } }
require(controller.connected && controller.decoder.goodFrames > 50,"no waveform received")
let before = controller.lastReferencePower!
let analytic = 160*180/2*cfg.voltageScale*cfg.currentScale
require(abs(before.powerW-analytic)<1,"synthetic watts do not match known waveform")
require(!controller.referencePowerRows.isEmpty,"no live estimated-watt records")
try controller.applyReferencePower(["measuredPower":500.0,"measuredVoltage":230.0])
require(abs(controller.lastReferencePower!.powerW-500)<1e-6,"reference fit not applied immediately")
RunLoop.main.run(until:Date().addingTimeInterval(2.3))
require(!controller.config.calibrated && controller.energy == 0 && controller.summaries.isEmpty,"estimate promoted to trusted measurement")
require(controller.referencePowerRows.allSatisfy{$0["power_w"] is NSNull && $0["energy_kwh"] is NSNull && $0["calibrated"] as? Bool == false},"estimated and physical watts contaminated")
require(controller.referencePowerRows.last?["estimated_power_w"] as? Double ?? 0 > 499,"updated estimate not saved")
let last = controller.lastReferencePower!.powerW,count = controller.referencePowerRows.count
controller.disconnect()
let settings = controller.recorder.root.appendingPathComponent("reference-power-settings.json")
let saved = try JSONDecoder().decode(MeterConfig.self,from:Data(contentsOf:settings))
require(saved.webhook.isEmpty && !saved.webhookEnabled && !saved.calibrated,"saved reference settings contain unsafe promotion or endpoint")
let other = MeterController(storageRoot:controller.recorder.root,enableDrive:false)
require(other.config.voltageOffset == 0,"reference settings leaked to a different host")
var matched = saved;matched.host = "192.168.1.2";matched.port = 8266
try JSONEncoder().encode(matched).write(to:settings,options:.atomic)
let restored = MeterController(storageRoot:controller.recorder.root,enableDrive:false)
require(restored.config.currentScale == matched.currentScale && !restored.config.calibrated,"matching endpoint reference settings not restored")
let report:[String:Any] = ["source":"native_power_loopback_test_NOT_hardware","passed":true,"valid_frames":controller.decoder.goodFrames,"saved_bytes":controller.recorder.savedBytes,"initial_estimated_w":before.powerW,"analytic_w":analytic,"fitted_estimated_w":last,"estimated_rows":count,"physical_power_w_remained_null":true,"calibrated_remained_false":true,"energy_not_accumulated":true,"endpoint_scoped_settings_restored":true,"hardware_accuracy_verified":false]
try jsonData(report).write(to:root.appendingPathComponent("result.json"),options:.atomic)
print("PASS: Native live estimated watts, 500 W reference fit, persistence and uncalibrated data isolation. Synthetic input only.")
