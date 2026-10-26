import Foundation
import CryptoKit

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
var cfg = MeterConfig(); cfg.protocolName = "isocket"; cfg.voltageScale = 1; cfg.currentScale = 1
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

// Regression against the user's unmodified hardware capture; no synthetic data substituted.
let capture = try Data(contentsOf:URL(fileURLWithPath:"Evidence/F251D351-实测原始.bin"))
check(capture.count == 126906,"real capture byte count")
check(SHA256.hash(data:capture).map { String(format:"%02x",$0) }.joined() == "f68a7366b80d76643a9cad2949d91a30f0b2e8874cddbee6e0b807272e2f6aad","real capture SHA256")
let observed = MeterConfig()
check(observed.host == "192.168.1.2" && observed.port == 8266 && observed.protocolName == "socket128","observed endpoint defaults")
try observed.validate()
let realDecoder = FrameDecoder(observed)
let realFrames = realDecoder.feed(capture)
check(realFrames.count == 242 && realDecoder.badFrames == 0,"all 242 observed frames pass full additive checksum")
check(realDecoder.discardedBytes == 1550 && realDecoder.buffer.isEmpty,"incomplete material skipped, not padded or counted as frames")
check(realFrames.allSatisfy { $0.voltage.count == 128 && $0.current.count == 128 && $0.rawSamples },"two raw channels, no physical calibration applied")
check(realFrames[0].voltage.prefix(3) == [57,64,72] && realFrames[0].current.prefix(3) == [17,18,19],"little-endian channel decoding")
let adc = try analyzeRaw(realFrames[0].voltage,realFrames[0].current,rate:6400)
check(adc.harmonics.isEmpty && adc.powerFactor == nil && adc.currentTHD == nil,"raw mode has no power factor or harmonics")
for chunkSize in [1,2,3,7,257,518,4096,65536] {
 let d = FrameDecoder(observed)
 var count = 0
 for pos in stride(from:0,to:capture.count,by:chunkSize) { count += d.feed(Data(capture[pos..<min(pos+chunkSize,capture.count)])).count }
 check(count == 242 && d.discardedBytes == 1550 && d.badFrames == 0 && d.buffer.isEmpty,"actual bytes survive TCP chunk size \(chunkSize)")
}
let firstOffset = 4, frameSize = 518
let actualPacket = Data(capture[firstOffset..<firstOffset+frameSize])
var damaged = actualPacket;damaged[20] ^= 1
let recovering = FrameDecoder(observed)
check(recovering.feed(damaged+actualPacket).count == 1 && recovering.badFrames >= 1,"damaged additive checksum rejected and next real frame recovered")
let partial = FrameDecoder(observed)
check(partial.feed(actualPacket.prefix(300)).isEmpty && partial.feed(actualPacket.dropFirst(300)).count == 1,"partial real frame waits for remainder")
var verified = observed;verified.calibrated = true;verified.voltageOffset = 11;verified.currentOffset = 18
let scaled = FrameDecoder(verified).feed(actualPacket)[0]
check(!scaled.rawSamples,"physical units only after explicit calibration confirmation")
close(scaled.voltage[0],(57-11)*verified.voltageScale,"confirmed voltage offset and scale applied")
close(scaled.current[0],(17-18)*verified.currentScale,"confirmed current offset and scale applied")
print("PASS TOTAL: \(checks) checks, including unmodified F251D351 real capture. Live integration still requires a new physical-device run.")

try runStorageChecks(capture:capture)
runDeviceCommandChecks()
