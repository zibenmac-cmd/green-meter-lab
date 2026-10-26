import Foundation

var checks = 0
func check(_ value:@autoclosure () -> Bool, _ name:String) {
    guard value() else { print("FAIL: "+name); exit(1) }; checks += 1
}
func awaitFinish(_ runner:ProbeRunner, seconds:Double = 12) {
    let end = Date().addingTimeInterval(seconds)
    while runner.busy && Date() < end { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.03)) }
    check(runner.phase == "finished","asynchronous test completes within deadline")
    check(runner.savedFolder != nil && runner.saveError.isEmpty,"report automatically saved")
    if let folder = runner.savedFolder {
        let data = try! Data(contentsOf:folder.appendingPathComponent("原始接收.bin"))
        check(data == runner.raw,"raw bytes round trip without transformation")
        let report = try! JSONDecoder().decode(ProbeReport.self,from:Data(contentsOf:folder.appendingPathComponent("诊断报告.json")))
        check(report.bytesReceived == data.count,"saved report matches raw byte count")
        check(!report.waveformDecoded && report.source.hasPrefix("loopback"),"mock data never labelled physical waveform")
    }
}

guard CommandLine.arguments.count >= 2 else { print("usage: tests <mock-folder>"); exit(1) }
let mock = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let ports = try JSONDecoder().decode([String:Int].self,from:Data(contentsOf:mock.appendingPathComponent("ports.json")))
let output = mock.appendingPathComponent("native-test-results",isDirectory:true)
var invalid = ProbeConfig(); invalid.host = "192.1681.1"
do { try invalid.validate(); check(false,"invalid IPv4 refused") } catch { checks += 1 }
invalid.host = "8.8.8.8"
do { try invalid.validate(); check(false,"public IP refused") } catch { checks += 1 }
invalid = ProbeConfig(); invalid.mode = .capture
do { try invalid.validate(); check(false,"YS command requires protocol confirmation") } catch { checks += 1 }
check(!redactReply("{\"password\":\"demo-only-secret\"}").contains("demo-only-secret"),"query text redacts password")
check(hexDump(Data([0,255,128,1])).contains("00 FF 80 01"),"hex preview preserves binary values")

let runner = ProbeRunner(outputRoot:output)
var c = ProbeConfig(); c.host = "127.0.0.1"
c.port = ports["passive"]!; try runner.start(c); awaitFinish(runner)
check(runner.report.tcpConnected && runner.report.rawReadSucceeded && runner.raw.count == 13,"passive stream accepts split binary without a frame parser")
check(!runner.report.requestSent,"passive test sends no application command")

c.port = ports["silent"]!; try runner.start(c); awaitFinish(runner)
check(runner.report.tcpConnected && !runner.report.rawReadSucceeded && runner.report.bytesReceived == 0,"TCP success is distinct from data success")

c.mode = .query; c.ysConfirmed = true; c.port = ports["query"]!
try runner.start(c); awaitFinish(runner)
check(runner.report.requestSent && runner.report.rawReadSucceeded,"ifconfig reply received")
let observedQuery = try String(contentsOf:mock.appendingPathComponent("query-command.txt"),encoding:.utf8)
check(observedQuery == "ifconfig","mock independently verifies exact query command")
let masked = try String(contentsOf:runner.savedFolder!.appendingPathComponent("配置回复-已隐藏常见密码字段.txt"),encoding:.utf8)
check(!masked.contains("demo-only-secret"),"saved configuration text redacts password")
check(String(data:runner.raw,encoding:.utf8)!.contains("demo-only-secret"),"raw bytes remain unmodified for protocol analysis")

c.mode = .capture; c.port = ports["capture"]!
try runner.start(c); awaitFinish(runner)
check(runner.report.requestSent && runner.report.stopCommandSent && runner.report.rawReadSucceeded,"bounded capture sends start and stop")
let until = Date().addingTimeInterval(1)
while !FileManager.default.fileExists(atPath:mock.appendingPathComponent("capture-stop.txt").path) && Date() < until { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.03)) }
check(FileManager.default.fileExists(atPath:mock.appendingPathComponent("capture-stop.txt").path),"mock independently confirms receiving stop $")

c.mode = .passive; c.port = ports["refused"]!; try runner.start(c); awaitFinish(runner)
check(!runner.report.tcpConnected && !runner.report.rawReadSucceeded && runner.report.error.contains("ECONNREFUSED"),"connection refusal saved separately from zero-byte connected result")

c.port = ports["timeout"]!; c.connectTimeout = 2; try runner.start(c); awaitFinish(runner)
check(!runner.report.tcpConnected && runner.report.error.contains("超时"),"silent TCP connection timeout is saved")

c.port = ports["silent"]!; c.connectTimeout = 8; try runner.start(c)
DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { runner.stop() }
awaitFinish(runner)
check(runner.report.cancelled && runner.report.tcpConnected,"manual cancellation preserves an established connection outcome")

print("PASS: \(checks) checks, including live loopback TCP push, silence, ifconfig, #/$ capture, refusal, timeout and cancellation. No physical device contacted.")
