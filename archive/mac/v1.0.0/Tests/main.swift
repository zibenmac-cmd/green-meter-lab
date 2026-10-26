import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { print("FAIL: \(label)"); exit(1) }; checks += 1
}
func close(_ a: Double, _ b: Double, _ label: String) { check(abs(a-b)<1e-8,label) }
func frame(_ payload: [UInt8], code: UInt8 = 0x14, crc: Bool = false) -> Data {
    var bytes: [UInt8] = [1,code,UInt8(payload.count/256),UInt8(payload.count%256)] + payload
    if crc { let c = crc16(bytes); bytes += [UInt8(c&255),UInt8(c>>8)] } else { bytes += [0x55,0xaa] }
    return Data(bytes)
}
var cfg = MeterConfig(); cfg.voltageScale = 1; cfg.currentScale = 1
try cfg.validate()
var payload: [UInt8] = []
for j in 0..<640 { let v = UInt16(bitPattern: Int16(j%2 == 0 ? 300 : -300)); payload += [UInt8(v>>8),UInt8(v&255)] }
for j in 0..<640 { payload.append(UInt8(bitPattern:Int8(j%2 == 0 ? 2 : -2))) }
let packet = frame(payload)
check(packet.count == 1926,"original 640-point frame size")
check(crc16(Array("123456789".utf8)) == 0x4b37,"CRC16 reference vector")
let decoder = FrameDecoder(cfg,expectRegistration:true)
let mac = Data([0x11,0x22,0x33,0x44,0x55,0x66])
check(decoder.feed(mac.prefix(2)).isEmpty,"split MAC registration")
check(decoder.feed(mac.suffix(4)+packet.prefix(51)).isEmpty,"registration plus partial frame")
let first = decoder.feed(packet.dropFirst(51)+packet)
check(first.count == 2,"coalesced and split frames")
check(decoder.deviceID == "11:22:33:44:55:66","registration identity")
check(first[0].voltage[1] == -300 && first[0].current[1] == -2,"signed BE voltage and int8 current")
let metrics = try analyze(first[0].voltage,first[0].current,rate:6400,lineHz:50)
close(metrics.voltageRMS,300,"voltage RMS");close(metrics.currentRMS,2,"current RMS");close(metrics.powerW,600,"true active power")
close(metrics.durationS,0.1,"configured sample duration")
let crcDecoder = FrameDecoder(cfg)
check(crcDecoder.feed(frame(payload,crc:true)).count == 1,"CRC verified frame")
var corrupt = Array(frame(payload,crc:true)); corrupt[10] ^= 0x20
let badDecoder = FrameDecoder(cfg)
check(badDecoder.feed(Data(corrupt)).isEmpty && badDecoder.badFrames > 0,"invalid CRC rejected")
check(FrameDecoder(cfg).feed(Data([0xff,0,0x77])+packet).count == 1,"garbage resynchronization")
let stats = FrameDecoder(cfg).feed(frame(Array(repeating:0,count:160),code:4))
check(stats.count == 1 && stats[0].registers.count == 80,"original 80-word parameter frame")
var ys = cfg;ys.protocolName = "ys8000";ys.points = 128;ys.headerHex = "68 01 02";ys.trailerHex = "03 04 05";ys.currentSign = -1
var ybytes: [UInt8] = [0x68,1,2]
for _ in 0..<128 { ybytes += [0x00,0xff] }
for _ in 0..<128 { ybytes += [0x02,0x00] }
ybytes += [3,4,5]
let yf = FrameDecoder(ys).feed(Data(ybytes))
check(yf.count == 1 && yf[0].voltage[0] == -256 && yf[0].current[0] == -2,"YS int16 little-endian layout and current sign")
let wave = try parseWaveCSV("\u{feff}I,V,label\r\n1,230,x\r\n-1,-230,x\r\n")
check(wave.0 == [230,-230] && wave.1 == [1,-1],"I,V,label CSV")
let legacy = try parseWaveCSV("Voltage,Current\n230,1\n-230,-1")
check(legacy.0 == [230,-230],"Windows Voltage,Current CSV")
do { _ = try parseWaveCSV("I,V\n,230"); check(false,"blank cell rejection") } catch { checks += 1 }
let v = (0..<640).map { 230*sqrt(2)*sin(2*Double.pi*50*Double($0)/6400) }
let i = (0..<640).map { 2*sqrt(2)*(sin(2*Double.pi*50*Double($0)/6400-Double.pi/3)+0.1*sin(2*Double.pi*150*Double($0)/6400)) }
let sine = try analyze(v,i,rate:6400,lineHz:50)
close(sine.powerW,230,"phase-aware active power");close(sine.currentTHD!,10,"third harmonic THD")
let negative = try analyze(v,i.map(-),rate:6400,lineHz:50)
check(negative.powerW < 0 && !negative.warnings.isEmpty,"negative power preserved")
var state = LoadState(); var calibrated = cfg;calibrated.calibrated = true
let t = Date(timeIntervalSince1970:100)
check(state.update(power:100,now:t,config:cfg) == "阈值与标定待确认","no uncalibrated load conclusion")
check(state.state == "阈值与标定待确认","published state also remains uncalibrated")
check(state.update(power:100,now:t,config:calibrated) == "待判定","hold-on starts pending")
check(state.update(power:100,now:t.addingTimeInterval(6),config:calibrated) == "运行中","hold-on reached")
check(state.update(power:0,now:t.addingTimeInterval(7),config:calibrated) == "运行中","short gap does not imply standby")
check(state.update(power:0,now:t.addingTimeInterval(28),config:calibrated) == "待机 / 未运行","hold-off reached")
check(state.update(power:-100,now:t.addingTimeInterval(30),config:calibrated) == "功率异常，暂停判断" && state.state == "功率异常，暂停判断","negative power clears published running state")
var invalid = cfg;invalid.webhookEnabled = true;invalid.webhook = "http://public.example/webhook/x"
do { try invalid.validate(); check(false,"public HTTP webhook rejected") } catch { checks += 1 }
print("PASS: \(checks) protocol, waveform, CSV, state and configuration checks. No hardware connected.")
