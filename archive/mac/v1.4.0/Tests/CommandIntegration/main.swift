import Foundation
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let ready = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("ready.json"))) as! [String:Int]
let controller = MeterController(storageRoot:root.appendingPathComponent("records"),enableDrive:false)
func pump(_ seconds:Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
func require(_ value:Bool,_ label:String) { guard value else { fatalError(label) } }
func observed() throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("observed.json"))) as! [String:Any] }
do { try controller.sendDeviceCommand(.relayOn,encoding:.singleByte); fatalError("offline command accepted") } catch { }
var cfg = MeterConfig();cfg.host = "127.0.0.1";cfg.port = ready["port"]!
try controller.start(cfg);pump(0.7)
require(controller.connected && controller.deviceCommandCanSend,"connected controls unavailable without waveform/calibration")
require((try observed()["received"] as? [Any])?.isEmpty == true,"unsolicited command on connection")
let sequence:[(DeviceCommand,DeviceCommandEncoding)] = [(.relayOn,.singleByte),(.relayOff,.singleByte),(.startData,.singleByte),(.stopData,.singleByte),(.relayOn,.manualUTF8),(.relayOff,.manualUTF8),(.startData,.manualUTF8),(.stopData,.manualUTF8)]
for (index,pair) in sequence.enumerated() {
    try controller.sendDeviceCommand(pair.0,encoding:pair.1)
    if index == 0 { do { try controller.sendDeviceCommand(.relayOff,encoding:.singleByte);fatalError("rapid command accepted") } catch { } }
    pump(1.12)
}
pump(2)
require(controller.connected,"automatic reconnect did not complete")
let state = try observed(), received = state["received"] as! [[String:Any]]
require(received.map{$0["hex"] as! String} == ["21","22","23","24","efbc81","e2809c","23","24"],"wire bytes or command count differ")
require(state["connections"] as? Int == 2,"expected one reconnect")
require(received.allSatisfy{$0["connection"] as? Int == 1},"relay/data commands replayed on reconnect")
require(controller.stoppedByUser,"explicit data pause not preserved")
controller.connectionBegan = Date().addingTimeInterval(-60);controller.lastData = nil
controller.tick();require(controller.connected && controller.reconnectAt == nil,"intentional pause triggered idle reconnect")
require(controller.deviceCommandMessage.contains("未核实"),"unconfirmed power presented as confirmed")
controller.disconnect();pump(0.2)
require(!controller.wantsConnection && !controller.deviceCommandCanSend,"manual disconnect did not disable controls")
controller.mode = "file"
do { try controller.sendDeviceCommand(.relayOn,encoding:.singleByte);fatalError("file replay command accepted") } catch { }
let report:[String:Any] = ["source":"native_loopback_command_test_NOT_hardware","passed":true,"received_hex":received.map{$0["hex"] as! String},"connections":state["connections"]!,"no_commands_on_connect_or_reconnect":true,"no_automatic_relay_retries":true,"rapid_duplicate_rejected":true,"intentional_data_pause_keeps_tcp":true,"offline_and_replay_disabled":true,"physical_relay_state_verified":false]
try jsonData(report).write(to:root.appendingPathComponent("result.json"),options:.atomic)
print("PASS: 8 exact wire commands; one reconnect without replay; offline/duplicate blocked; physical relay not tested.")
