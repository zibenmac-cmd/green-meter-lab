import Foundation
import Network

final class ProbeRunner {
    var onUpdate: (() -> Void)?
    var config = ProbeConfig()
    var report = ProbeReport(ProbeConfig())
    var phase = "idle"
    var status = "准备测试"
    var detail = "默认只尝试连接和接收，不要求先填写波形参数。"
    var raw = Data()
    var logs: [String] = []
    var outputRoot: URL
    var savedFolder: URL?
    var saveError = ""
    var busy: Bool { ["connecting","receiving","stopping"].contains(phase) }
    private var conn: NWConnection?
    private var token = UUID()
    private var connectTimer: DispatchWorkItem?
    private var receiveTimer: DispatchWorkItem?
    private var stopTimer: DispatchWorkItem?
    private var started = Date()
    private var waitingDescription = ""
    private var startCommandAttempted = false
    private let limit = 2_097_152
    init(outputRoot: URL) { self.outputRoot = outputRoot }

    func start(_ c: ProbeConfig) throws {
        guard !busy else { throw ProbeError.invalid("本次测试尚未结束，请先停止") }
        guard saveError.isEmpty else { throw ProbeError.invalid(saveError) }
        try c.validate()
        config = c; report = ProbeReport(c); raw = Data(); logs = []; savedFolder = nil; saveError = ""
        report.networkAtStart = localAddresses(target:c.host)
        token = UUID(); let current = token; started = Date(); waitingDescription = ""; startCommandAttempted = false
        phase = "connecting"; status = "正在连接 \(c.host):\(c.port)"
        detail = "最多等待 \(Int(c.connectTimeout)) 秒。TCP 建立后会继续检查是否真的收到字节。"
        log(c.isLoopback ? "本机回环自测：本次不能证明插座可用" : "设备 IP 测试：本次不切换 Wi-Fi，不改变插座设置")
        log("连接目标 \(c.host):\(c.port)，模式：\(c.mode.title)")
        log("测试开始时本机 IPv4："+networkSummary(report.networkAtStart))
        if !report.networkAtStart.contains(where: { $0.sharesTargetSubnet }) {
            log("目标不在已读到的本机直连 IPv4 网段，可能经过网关；此提示不单独判定连接失败")
        }
        let connection = NWConnection(host:NWEndpoint.Host(c.host),port:NWEndpoint.Port(rawValue:UInt16(c.port))!,using:.tcp)
        conn = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection, self.token == current, self.conn === connection else { return }
            switch state {
            case .ready:
                self.connectTimer?.cancel(); self.report.tcpConnected = true
                self.report.connectDurationMs = Int(Date().timeIntervalSince(self.started)*1000)
                if let path = connection.currentPath {
                    self.report.connectionPath = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "有线网络" : path.usesInterfaceType(.loopback) ? "本机回环" : "其他 / 系统路由"
                }
                self.phase = "receiving"; self.status = "TCP 已连接 · 正在等待数据"
                self.detail = "已建立连接，不代表已有电表数据。将接收约 \(Int(c.receiveSeconds)) 秒。"
                self.log("TCP 已连接，开始接收原始字节"); self.receive(connection,current)
                if let command = c.mode.command {
                    self.startCommandAttempted = c.mode == .capture
                    connection.send(content:command,completion:.contentProcessed { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self = self, self.token == current, self.phase == "receiving" else { return }
                            if let error = error { self.report.error = "发送命令失败：\(error)"; self.log(self.report.error); self.finishCurrent() }
                            else { self.report.requestSent = true; self.log("已发送 \(c.mode == .query ? "ifconfig" : "#")（无附加回车）"); self.changed() }
                        }
                    })
                }
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self = self, self.token == current, self.phase == "receiving" else { return }
                    self.finishCurrent()
                }
                self.receiveTimer = deadline; DispatchQueue.main.asyncAfter(deadline:.now()+c.receiveSeconds,execute:deadline)
            case .waiting(let error):
                let description = self.errorMessage(error)
                if description != self.waitingDescription { self.waitingDescription = description; self.log("连接等待：\(description)") }
                self.detail = "系统尚未建立 TCP：\(description)。继续等待，超时将自动保存报告。"
            case .failed(let error):
                self.report.error = self.errorMessage(error); self.log(self.report.error); self.finishCurrent(sendStop:false)
            case .cancelled:
                if self.busy { self.report.error = "TCP 连接被取消"; self.finishCurrent(sendStop:false) }
            default: break
            }
            self.changed()
        }
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self = self, let connection = connection, self.token == current, self.conn === connection, !self.report.tcpConnected else { return }
            self.report.error = "连接超时（\(Int(c.connectTimeout)) 秒）" + (self.waitingDescription.isEmpty ? "" : "；系统状态："+self.waitingDescription)
            self.log(self.report.error); self.finishCurrent(sendStop:false)
        }
        connectTimer = timeout; DispatchQueue.main.asyncAfter(deadline:.now()+c.connectTimeout,execute:timeout)
        connection.start(queue:.main); changed()
    }

    private func receive(_ connection: NWConnection, _ current: UUID) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self, weak connection] data,_,closed,error in
            guard let self = self, let connection = connection, self.token == current, self.conn === connection, self.busy else { return }
            if let data = data, !data.isEmpty {
                let room = max(0,self.limit-self.raw.count)
                self.raw.append(contentsOf:data.prefix(room)); self.report.bytesReceived = self.raw.count
                if self.phase != "stopping" { self.status = "已收到 \(self.raw.count.formatted()) 字节原始数据" }
                if self.logs.count < 5 || self.raw.count == data.count { self.log("收到第一段内容：\(data.count) 字节；本工具不依赖波形解析") }
                self.detail = self.config.isLoopback ? "这是本机测试数据，不是插座实测。" : "原始接收已发生。尚未把这些字节解释为电压、电流。"
                if self.raw.count >= self.limit { self.report.captureLimitReached = true; self.log("达到 2 MiB 上限，结束本次读取"); self.finishCurrent(); return }
            }
            if closed || error != nil {
                self.report.peerClosed = closed
                if let error = error { self.report.error = self.errorMessage(error); self.log(self.report.error) }
                if closed { self.log("对端关闭连接") }
                self.finishCurrent(sendStop:false)
            } else { self.receive(connection,current) }
            self.changed()
        }
    }

    func stop() { guard busy else { return }; report.cancelled = true; log("操作者停止本次测试"); finishCurrent() }
    private func finishCurrent(sendStop: Bool = true) {
        guard busy else { return }
        connectTimer?.cancel(); receiveTimer?.cancel()
        if phase == "stopping" { return }
        if sendStop, report.tcpConnected, config.mode == .capture, startCommandAttempted, let connection = conn {
            phase = "stopping"; status = "正在结束读取并发送停止指令 $"
            let current = token
            connection.send(content:Data("$".utf8),completion:.contentProcessed { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self, self.token == current, self.phase == "stopping" else { return }
                    if let error = error { self.report.error += " 停止指令发送失败：\(error)"; self.log("停止指令发送失败") }
                    else { self.report.stopCommandSent = true; self.log("$ 已发往 TCP 连接；未确认设备实际执行") }
                    self.finalize()
                }
            })
            let fallback = DispatchWorkItem { [weak self] in
                guard let self = self, self.token == current, self.phase == "stopping" else { return }
                self.report.error += " 停止指令发送超时，设备是否停止需实测确认"; self.log("停止指令发送超时"); self.finalize()
            }
            stopTimer = fallback; DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:fallback); changed()
        } else { finalize() }
    }

    private func finalize() {
        guard busy else { return }
        connectTimer?.cancel(); receiveTimer?.cancel(); stopTimer?.cancel()
        token = UUID(); let old = conn; conn = nil; old?.cancel()
        report.bytesReceived = raw.count; report.endedAt = ISO8601DateFormatter().string(from:Date()); report.conclude()
        report.networkAtEnd = localAddresses(target:config.host)
        phase = "finished"; status = report.conclusion
        detail = "本次目标 \(config.host):\(config.port)。" + (report.rawReadSucceeded ? "已收到原始字节，实物协议与波形仍待核对。" : report.error.isEmpty ? "连接已建立但本次没有内容返回。请核对设备是否需要查询或采集指令。" : report.error)
        log("测试结束："+report.conclusion)
        log("测试结束时本机 IPv4："+networkSummary(report.networkAtEnd))
        persist(); changed()
    }

    func persist(to root: URL? = nil) {
        let destination = root ?? outputRoot
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd-HHmmss"
        let folder = destination.appendingPathComponent(stamp.string(from:started)+"-"+String(report.testID.prefix(8)),isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try raw.write(to:folder.appendingPathComponent(report.rawFile),options:.atomic)
            try encoder.encode(report).write(to:folder.appendingPathComponent("诊断报告.json"),options:.atomic)
            try reportSummary(report).write(to:folder.appendingPathComponent("测试结果.txt"),atomically:true,encoding:.utf8)
            try logs.joined(separator:"\n").write(to:folder.appendingPathComponent("通信日志.txt"),atomically:true,encoding:.utf8)
            try hexDump(raw,limit:1024).write(to:folder.appendingPathComponent("原始数据预览.txt"),atomically:true,encoding:.utf8)
            if config.mode == .query, let text = String(data:raw,encoding:.utf8) {
                try redactReply(text).write(to:folder.appendingPathComponent("配置回复-已隐藏常见密码字段.txt"),atomically:true,encoding:.utf8)
            }
            outputRoot = destination; savedFolder = folder; saveError = ""
        } catch {
            saveError = "保存失败：\(error.localizedDescription)。数据仍在本次窗口中，请先选择可写目录并保存，再开始下一次测试。"
        }
    }
    func prepareForQuit() { if busy { stop() } }
    private func changed() { onUpdate?() }
    private func log(_ text: String) { let date = DateFormatter(); date.dateFormat = "HH:mm:ss.SSS"; logs.append("[\(date.string(from:Date()))] \(text)"); if logs.count > 160 { logs.removeFirst() } }
    private func errorMessage(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED): return "端口拒绝连接：目标有回复，但该端口未接受 TCP（ECONNREFUSED）"
        case .posix(.ENETUNREACH), .posix(.EHOSTUNREACH): return "设备网络或主机不可达（\(error)）"
        case .posix(.EACCES), .posix(.EPERM): return "系统拒绝网络访问（\(error)）；检查本地网络权限"
        case .posix(.ETIMEDOUT): return "TCP 连接超时（ETIMEDOUT）"
        default: return "TCP 错误：\(error)；\(error.localizedDescription)"
        }
    }
}
