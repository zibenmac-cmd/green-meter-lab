import Foundation

enum ProbeMode: Int, Codable {
    case passive = 0, query = 1, capture = 2
    var title: String {
        switch self {
        case .passive: return "只连接，等待设备主动返回"
        case .query: return "YS8000：查询配置 ifconfig"
        case .capture: return "YS8000：读取原始数据 # / $"
        }
    }
    var command: Data? {
        switch self { case .passive: return nil; case .query: return Data("ifconfig".utf8); case .capture: return Data("#".utf8) }
    }
}

struct ProbeConfig: Codable {
    var host = "192.168.1.1"
    var port = 8266
    var mode = ProbeMode.passive
    var ysConfirmed = false
    var connectTimeout = 8.0
    var receiveSeconds: Double { mode == .passive ? 5 : 3 }
    var isLoopback: Bool { host.split(separator:".").first == "127" }
    func validate() throws {
        let parts = host.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ Int($0) }).count == 4 else { throw ProbeError.invalid("请填写完整 IPv4 地址，例如 192.168.1.1") }
        let p = parts.compactMap { Int($0) }
        guard p.allSatisfy({ (0...255).contains($0) }),
              p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254) else {
            throw ProbeError.invalid("本工具仅测试局域网 IPv4 或本机回环地址")
        }
        guard (1...65535).contains(port), (1...30).contains(connectTimeout) else { throw ProbeError.invalid("端口须为 1–65535") }
        guard mode == .passive || ysConfirmed else { throw ProbeError.invalid("使用查询或采集命令前，请勾选确认设备使用 YS8000 手册协议；不确定时先做“只连接”测试") }
    }
}

enum ProbeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

struct ProbeReport: Codable {
    var app = "插座 IP 读取测试器"
    var version = "1.0.1"
    var testID = UUID().uuidString
    var startedAt = ISO8601DateFormatter().string(from:Date())
    var endedAt = ""
    var host: String
    var port: Int
    var testMode: String
    var source: String
    var tcpConnected = false
    var bytesReceived = 0
    var rawReadSucceeded = false
    var waveformDecoded = false
    var requestSent = false
    var stopCommandSent = false
    var captureLimitReached = false
    var peerClosed = false
    var cancelled = false
    var connectDurationMs: Int?
    var networkAtStart: [ProbeAddress] = []
    var networkAtEnd: [ProbeAddress] = []
    var connectionPath = ""
    var error = ""
    var conclusion = "尚未开始"
    var rawFile = "原始接收.bin"
    var notes = "收到字节仅证明该地址返回了内容，不确认设备身份、波形协议、采样率或测量标定。没有把测试数据写入绿电实验室。"
    init(_ c: ProbeConfig) {
        host = c.host; port = c.port; testMode = c.mode.title
        source = c.isLoopback ? "loopback_self_test_NOT_hardware" : "device_ip_test_NOT_identity_verified"
    }
    mutating func conclude() {
        rawReadSucceeded = bytesReceived > 0
        if rawReadSucceeded {
            conclusion = source.hasPrefix("loopback") ? "本机自测收到 \(bytesReceived) 字节（非插座数据）" : "收到 \(bytesReceived) 字节原始数据（尚未解析电压、电流）"
        } else if tcpConnected {
            conclusion = "TCP 已连接，本次未收到任何字节"
        } else {
            conclusion = cancelled ? "测试已取消，TCP 未建立" : "TCP 未建立连接"
        }
    }
}

struct ProbeAddress: Codable {
    var interface: String
    var ipv4: String
    var netmask: String
    var sharesTargetSubnet: Bool
}

func ipv4Value(_ string: String) -> UInt32? {
    let p = string.split(separator:".",omittingEmptySubsequences:false)
    guard p.count == 4 else { return nil }
    var result: UInt32 = 0
    for item in p { guard let n = UInt32(item), n <= 255 else { return nil }; result = (result << 8) | n }
    return result
}

func localAddresses(target: String) -> [ProbeAddress] {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
    defer { freeifaddrs(addresses) }
    func numeric(_ address: UnsafeMutablePointer<sockaddr>?) -> String {
        guard let a = address else { return "" }
        var value = [CChar](repeating:0,count:Int(NI_MAXHOST))
        guard getnameinfo(a,socklen_t(a.pointee.sa_len),&value,socklen_t(value.count),nil,0,NI_NUMERICHOST) == 0 else { return "" }
        return String(cString:value)
    }
    var result: [ProbeAddress] = []
    var node: UnsafeMutablePointer<ifaddrs>? = first
    while let item = node {
        defer { node = item.pointee.ifa_next }
        guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        let ip = numeric(address), mask = numeric(item.pointee.ifa_netmask)
        let local = ipv4Value(ip), remote = ipv4Value(target), bits = ipv4Value(mask)
        let same = local != nil && remote != nil && bits != nil && ((local! & bits!) == (remote! & bits!))
        result.append(ProbeAddress(interface:String(cString:item.pointee.ifa_name),ipv4:ip,netmask:mask,sharesTargetSubnet:same))
    }
    return result
}

func networkSummary(_ addresses: [ProbeAddress]) -> String {
    addresses.isEmpty ? "无法读取本机 IPv4 接口" : addresses.map { "\($0.interface) \($0.ipv4)（掩码 \($0.netmask)）" }.joined(separator:"；")
}

func hexDump(_ data: Data, limit: Int = 1024) -> String {
    guard !data.isEmpty else { return "尚无接收数据。\n先确认 TCP 连接，再检查是否需要设备采集指令。" }
    let a = Array(data.prefix(limit))
    let rows = stride(from:0,to:a.count,by:16).map { offset -> String in
        let part = Array(a[offset..<min(offset+16,a.count)])
        let hex = part.map { String(format:"%02X",$0) }.joined(separator:" ")
        return String(format:"%06X",offset)+"   "+hex
    }
    return rows.joined(separator:"\n") + (data.count > limit ? "\n… 界面仅显示前 \(limit) 字节，文件保存全部已接收内容。" : "")
}

func redactReply(_ s: String) -> String {
    s.replacingOccurrences(of:"(?i)([\"']?(?:password|passwd|pwd|pass|token|secret|key)[\"']?\\s*[:=]\\s*)(?:[\"'][^\"']*[\"']|[^\\s,;}]+)",with:"$1***",options:.regularExpression)
}

func reportSummary(_ r: ProbeReport) -> String {
    """
    插座 IP 读取测试器 1.0.1
    测试编号：\(r.testID)
    开始：\(r.startedAt)
    结束：\(r.endedAt)
    目标：\(r.host):\(r.port)
    模式：\(r.testMode)
    来源：\(r.source)
    TCP 连接：\(r.tcpConnected ? "成功" : "未成功")
    接收字节：\(r.bytesReceived)
    查询/开始命令：\(r.requestSent ? "已发送" : "未发送")
    停止命令 $：\(r.stopCommandSent ? "已发往 TCP 连接，未确认设备执行" : "未发送")
    设备关闭连接：\(r.peerClosed ? "是" : "否")
    结果：\(r.conclusion)
    错误或补充：\(r.error.isEmpty ? "无" : r.error)
    测试开始时本机地址：\(networkSummary(r.networkAtStart))
    测试结束时本机地址：\(networkSummary(r.networkAtEnd))
    TCP 网络路径：\(r.connectionPath.isEmpty ? "未建立 / 未读取" : r.connectionPath)

    \(r.notes)

    下一步：
    - TCP 未连接：先核对插座热点、实际 IP/端口及 macOS 本地网络权限。
    - TCP 已连接但 0 字节：核对设备是否需要查询或启动采集命令。
    - 收到字节：保存本次报告和原始 BIN，用于核对实际设备协议。
    """
}
