import Foundation

enum MeterError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

struct MeterConfig: Codable {
    var transport = "client"
    var protocolName = "socket128"
    var host = "192.168.1.2"
    var bindIP = "127.0.0.1"
    var port = 8266
    var registration = false
    var discovery = false
    var sampleRate = 6400.0
    var lineHz = 50.0
    var voltageScale = 1.935205
    var currentScale = 0.011848
    var voltageOffset = 0.0
    var currentOffset = 0.0
    var currentSign = 1.0
    var points = 128
    var headerHex = ""
    var trailerHex = ""
    var littleEndian = true
    var calibrated = false
    var stateOn = 50.0
    var stateOff = 10.0
    var holdOn = 5.0
    var holdOff = 20.0
    var webhook = ""
    var webhookEnabled = false
    var webhookInterval = 5.0

    func validate() throws {
        guard ["client", "server"].contains(transport), ["isocket", "ys8000", "socket128"].contains(protocolName) else { throw MeterError.invalid("连接方式或协议无效") }
        if protocolName == "socket128" && (transport != "client" || registration || discovery) { throw MeterError.invalid("本次插座使用电脑主动连接；无需注册 MAC 或设备发现") }
        guard (1...65535).contains(port), (400...20000).contains(sampleRate), [50.0,60.0].contains(lineHz) else { throw MeterError.invalid("端口、采样率或电网频率无效") }
        guard abs(sampleRate/lineHz - (sampleRate/lineHz).rounded()) < 1e-8 else { throw MeterError.invalid("采样率应为电网频率的整数倍，以计算完整周波谐波") }
        guard voltageScale.isFinite, currentScale.isFinite, voltageScale > 0, currentScale > 0,
              voltageOffset.isFinite, currentOffset.isFinite, [-1.0,1.0].contains(currentSign) else { throw MeterError.invalid("标定参数无效") }
        guard [host, bindIP].allSatisfy({ isIPv4($0) }) else { throw MeterError.invalid("请填写 IPv4 地址，例如 192.168.1.1") }
        guard stateOn.isFinite, stateOff.isFinite, stateOn > stateOff, stateOff >= 0,
              holdOn.isFinite, holdOff.isFinite, (0...600).contains(holdOn), (0...600).contains(holdOff) else { throw MeterError.invalid("运行阈值须大于待机阈值，保持时间须为 0–600 秒") }
        guard (8...256).contains(points), webhookInterval.isFinite, (1...300).contains(webhookInterval) else { throw MeterError.invalid("采样点数或推送间隔无效") }
        if webhookEnabled {
            guard let u = URL(string: webhook), let h = u.host, u.user == nil, u.password == nil, u.fragment == nil,
                  u.scheme == "https" || (u.scheme == "http" && isLocalHost(h)) else {
                throw MeterError.invalid("Webhook 须为 HTTPS 或局域网 HTTP 地址，且不可在 URL 中填写密码")
            }
        }
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && (Int($0).map { (0...255).contains($0) } ?? false) }
    }
    static func isLocalHost(_ s: String) -> Bool {
        if ["localhost", "::1"].contains(s) || s.hasSuffix(".local") { return true }
        guard isIPv4(s) else { return false }
        let n = s.split(separator: ".").compactMap { Int($0) }
        return n[0] == 10 || n[0] == 127 || (n[0] == 192 && n[1] == 168) || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 169 && n[1] == 254)
    }
    private func isIPv4(_ s: String) -> Bool { Self.isIPv4(s) }
    private func isLocalHost(_ s: String) -> Bool { Self.isLocalHost(s) }
}

func hexBytes(_ s: String) throws -> [UInt8] {
    let cleaned = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
    guard cleaned.count % 2 == 0, cleaned.count <= 32 else { throw MeterError.invalid("十六进制标记长度无效") }
    let a = Array(cleaned)
    return try stride(from: 0, to: a.count, by: 2).map { i in
        guard let n = UInt8(String(a[i...i+1]), radix: 16) else { throw MeterError.invalid("帧标记包含非十六进制字符") }; return n
    }
}

func crc16(_ a: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xffff
    for b in a { crc ^= UInt16(b); for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xa001 : crc >> 1 } }
    return crc
}

struct MeterFrame {
    var voltage: [Double] = []
    var current: [Double] = []
    var registers: [Int16] = []
    var integrity = ""
    var rawSamples = false
    var voltageADC: [Double] = []
    var currentADC: [Double] = []
}

/// Observed capture F251D351: 68 + LE16(512) + 256 LE16 sample words
/// + LE16 additive checksum(length + all words, modulo 65536) + 11.
/// Channel mapping follows the supplied two-channel layout; physical scales remain unverified.
func socket128Checksum(_ bytes: [UInt8]) -> UInt16 {
    precondition(bytes.count >= 515)
    var sum: UInt16 = 0
    for p in stride(from: 1, to: 515, by: 2) {
        sum = sum &+ (UInt16(bytes[p]) | UInt16(bytes[p+1]) << 8)
    }
    return sum
}

/// Port of the single-phase iSocket 0x14/0x04 data layout, with stream buffering.
final class FrameDecoder {
    var config: MeterConfig
    var buffer: [UInt8] = []
    var needsRegistration: Bool
    var deviceID = ""
    var badFrames = 0
    var discardedBytes = 0
    var goodFrames = 0
    init(_ config: MeterConfig, expectRegistration: Bool = false) {
        self.config = config; needsRegistration = expectRegistration
    }
    func feed(_ data: Data) -> [MeterFrame] {
        buffer.append(contentsOf: data)
        if buffer.count > 1_048_576 { discardedBytes += buffer.count; buffer.removeAll(); badFrames += 1; return [] }
        if needsRegistration {
            guard buffer.count >= 6 else { return [] }
            deviceID = buffer.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
            buffer.removeFirst(6); needsRegistration = false
        }
        if config.protocolName == "socket128" { return decodeSocket128() }
        return config.protocolName == "isocket" ? decodeISocket() : decodeYS()
    }
    private func decodeSocket128() -> [MeterFrame] {
        var out: [MeterFrame] = []
        var cursor = 0
        while buffer.count-cursor >= 3 {
            guard buffer[cursor] == 0x68, buffer[cursor+1] == 0, buffer[cursor+2] == 2 else {
                cursor += 1; discardedBytes += 1; continue
            }
            guard buffer.count-cursor >= 518 else { break }
            let bytes = Array(buffer[cursor..<cursor+518])
            let checksum = UInt16(bytes[515]) | UInt16(bytes[516]) << 8
            guard bytes[517] == 0x11, socket128Checksum(bytes) == checksum else {
                cursor += 1; discardedBytes += 1; badFrames += 1; continue
            }
            func word(_ p: Int) -> Double { Double(Int16(bitPattern:UInt16(bytes[p]) | UInt16(bytes[p+1]) << 8)) }
            var frame = MeterFrame(integrity:"68 · 512 字节 · 16 位累加校验通过 · 尾字节 11", rawSamples:!config.calibrated)
            for j in 0..<128 {
                let v = word(3+j*2), i = word(259+j*2)
                frame.voltageADC.append(v); frame.currentADC.append(i)
                frame.voltage.append(config.calibrated ? (v-config.voltageOffset)*config.voltageScale : v)
                frame.current.append(config.calibrated ? (i-config.currentOffset)*config.currentScale*config.currentSign : i)
            }
            cursor += 518; goodFrames += 1; out.append(frame)
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return out
    }
    private func decodeISocket() -> [MeterFrame] {
        var out: [MeterFrame] = []
        while buffer.count >= 4 {
            guard buffer[0] == 1, [0x14,0x04,0x03].contains(buffer[1]) else { buffer.removeFirst(); discardedBytes += 1; continue }
            let length = Int(buffer[2])*256 + Int(buffer[3]), code = buffer[1]
            guard length > 0, length <= (code == 0x14 ? 1920 : 160), (code == 0x14 ? length % 3 == 0 : length % 2 == 0) else { buffer.removeFirst(); badFrames += 1; continue }
            // The supplied Windows implementation supports 640 samples per 0x14 frame.
            guard code != 0x14 || length == 1920 else { buffer.removeFirst(); badFrames += 1; continue }
            guard buffer.count >= length+6 else { break }
            let frame = Array(buffer.prefix(length+6)), tail = Array(frame.suffix(2)), crc = crc16(Array(frame.dropLast(2)))
            let fixedTail = tail == [0x55,0xaa]
            guard fixedTail || tail == [UInt8(crc & 255),UInt8(crc >> 8)] else { buffer.removeFirst(); badFrames += 1; continue }
            var f = MeterFrame(integrity: fixedTail ? "固定帧尾 55AA" : "CRC16 通过")
            if code == 0x14 {
                let n = length/3
                for j in 0..<n {
                    let rawV = Int16(bitPattern: UInt16(frame[4+j*2])*256 + UInt16(frame[5+j*2]))
                    let rawI = Int8(bitPattern: frame[4+n*2+j])
                    f.voltage.append((Double(rawV)-config.voltageOffset)*config.voltageScale)
                    f.current.append((Double(rawI)-config.currentOffset)*config.currentScale*config.currentSign)
                }
            } else {
                for j in 0..<length/2 { f.registers.append(Int16(bitPattern: UInt16(frame[4+j*2])*256 + UInt16(frame[5+j*2]))) }
            }
            buffer.removeFirst(length+6); goodFrames += 1; out.append(f)
        }
        return out
    }
    private func decodeYS() -> [MeterFrame] {
        guard let header = try? hexBytes(config.headerHex), let trailer = try? hexBytes(config.trailerHex), header.count == 3, trailer.count == 3 else { return [] }
        let total = config.points*4+6
        var out: [MeterFrame] = []
        while buffer.count >= 3 {
            guard Array(buffer.prefix(3)) == header else { buffer.removeFirst(); discardedBytes += 1; continue }
            guard buffer.count >= total else { break }
            guard Array(buffer[(total-3)..<total]) == trailer else { buffer.removeFirst(); badFrames += 1; continue }
            func word(_ pos: Int) -> Double {
                let hi = config.littleEndian ? buffer[pos+1] : buffer[pos]
                let lo = config.littleEndian ? buffer[pos] : buffer[pos+1]
                return Double(Int16(bitPattern: UInt16(hi)*256+UInt16(lo)))
            }
            var f = MeterFrame(integrity: "指定帧头/帧尾匹配（无 CRC 定义）")
            for j in 0..<config.points {
                f.voltage.append((word(3+j*2)-config.voltageOffset)*config.voltageScale)
                f.current.append((word(3+config.points*2+j*2)-config.currentOffset)*config.currentScale*config.currentSign)
            }
            buffer.removeFirst(total); goodFrames += 1; out.append(f)
        }
        return out
    }
}

struct ElectricalMetrics: Codable {
    var voltageRMS: Double
    var currentRMS: Double
    var powerW: Double
    var apparentVA: Double
    var powerFactor: Double?
    var currentTHD: Double?
    var harmonics: [Double]
    var count: Int
    var durationS: Double
    var warnings: [String]
}

func analyzeRaw(_ v: [Double], _ i: [Double], rate: Double) throws -> ElectricalMetrics {
    guard v.count == i.count, v.count >= 16, rate >= 400,
          (v+i).allSatisfy({ $0.isFinite && abs($0) <= 32768 }) else { throw MeterError.invalid("原始 ADC 波形无效") }
    let n = Double(v.count)
    return ElectricalMetrics(voltageRMS:sqrt(v.reduce(0) { $0+$1*$1 }/n),
        currentRMS:sqrt(i.reduce(0) { $0+$1*$1 }/n),powerW:0,apparentVA:0,
        powerFactor:nil,currentTHD:nil,harmonics:[],count:v.count,durationS:n/rate,
        warnings:["当前显示原始 ADC 计数，包含直流零点；不能直接当作 V、A 或 W。", "通道换算、零点及实际采样率仍需与参考仪表核对；暂不判断负载开关或累计用电量。"])
}

func analyze(_ v: [Double], _ i: [Double], rate: Double, lineHz: Double) throws -> ElectricalMetrics {
    guard v.count == i.count, (16...640000).contains(v.count), rate >= 400,
          v.allSatisfy({ $0.isFinite && abs($0) <= 2000 }), i.allSatisfy({ $0.isFinite && abs($0) <= 500 }) else { throw MeterError.invalid("波形长度、有限值或量程检查未通过") }
    let n = Double(v.count), vr = sqrt(v.reduce(0) { $0+$1*$1 }/n), ir = sqrt(i.reduce(0) { $0+$1*$1 }/n)
    let p = zip(v,i).reduce(0) { $0 + $1.0 * $1.1 }/n, s = vr*ir
    let cycle = Int((rate/lineHz).rounded()), hn = min(i.count/cycle*cycle, cycle*10)
    var harmonics: [Double] = [], warnings: [String] = []
    if cycle >= 8, hn >= cycle {
        for h in 1...min(15, max(1,Int(rate/(2*lineHz))-1)) {
            var re = 0.0, im = 0.0
            for j in 0..<hn { let a = 2 * Double.pi * Double(h) * lineHz * Double(j)/rate; re += i[j]*cos(a); im -= i[j]*sin(a) }
            harmonics.append(sqrt(2)*hypot(re,im)/Double(hn))
        }
    }
    let fundamental = harmonics.first ?? 0
    let thd = fundamental > max(1e-6,ir*0.01) ? sqrt(harmonics.dropFirst().reduce(0) { $0+$1*$1 })/fundamental*100 : nil
    if p < 0 { warnings.append("有功功率为负：核对通道顺序、极性和标定；未取绝对值。") }
    if ir > 0 && abs(i.reduce(0,+)/n) > ir*0.2 { warnings.append("电流直流偏置较大，请核对零点与系数。") }
    if thd == nil { warnings.append("电流基波过小，暂不计算 THD。") }
    return ElectricalMetrics(voltageRMS: vr,currentRMS: ir,powerW: p,apparentVA: s,powerFactor: s > 1e-9 ? max(-1,min(1,p/s)) : nil,currentTHD: thd,harmonics: harmonics,count: v.count,durationS: n/rate,warnings: warnings)
}

func parseWaveCSV(_ text: String) throws -> ([Double],[Double]) {
    let lines = text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    var headerIndex: Int?, vi: Int?, ii: Int?, size = 0
    func cells(_ s: String) -> [String] { s.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))).lowercased() } }
    for (j,l) in lines.prefix(10).enumerated() {
        let h = cells(l)
        if let v = h.firstIndex(where: { ["v","voltage"].contains($0) }), let i = h.firstIndex(where: { ["i","current"].contains($0) }) {
            headerIndex = j; vi = v; ii = i; size = h.count; break
        }
    }
    guard let start = headerIndex, let vIndex = vi, let iIndex = ii else { throw MeterError.invalid("CSV 需要 I,V 或 Voltage,Current 表头") }
    var v: [Double] = [], i: [Double] = []
    for l in lines.dropFirst(start+1) {
        let c = cells(l)
        guard c.count == size, let vv = Double(c[vIndex]), let iv = Double(c[iIndex]), vv.isFinite, iv.isFinite else { throw MeterError.invalid("CSV 包含空值、非数字或错误列数") }
        v.append(vv); i.append(iv)
        if v.count > 640000 { throw MeterError.invalid("CSV 最多 640,000 对采样") }
    }
    return (v,i)
}

struct LoadState {
    var state = "待判定"
    var candidate = ""
    var since: Date?
    mutating func update(power: Double, now: Date, config: MeterConfig) -> String {
        if !config.calibrated { state = "阈值与标定待确认"; candidate = ""; since = nil; return state }
        if power < 0 { state = "功率异常，暂停判断"; candidate = ""; since = nil; return state }
        if !["待判定", "运行中", "待机 / 未运行"].contains(state) { state = "待判定" }
        let next = power >= config.stateOn ? "运行中" : power <= config.stateOff ? "待机 / 未运行" : ""
        guard !next.isEmpty else { candidate = ""; since = nil; return state }
        if next != candidate { candidate = next; since = now }
        if now.timeIntervalSince(since ?? now) >= (next == "运行中" ? config.holdOn : config.holdOff) { state = next }
        return state
    }
}
