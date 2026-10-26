import AppKit
import WebKit
import Network
import Foundation
import UniformTypeIdentifiers

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class MeterController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var web: WKWebView?
    var config = MeterConfig()
    var decoder = FrameDecoder(MeterConfig())
    var connection: NWConnection?
    var listener: NWListener?
    var discoveryListener: NWListener?
    var discoveryPeers: [NWConnection] = []
    var timer: Timer?
    var generation = 0
    var connected = false
    var collecting = false
    var stoppedByUser = false
    var mode = "empty"
    var bytesReceived = 0
    var raw = Data()
    var captureUntil: Date?
    var textQueryUntil: Date?
    var lastData: Date?
    var lastFrame = MeterFrame()
    var lastMetrics: ElectricalMetrics?
    var hardware: [String:Double] = [:]
    var loadState = LoadState()
    var source = "尚无数据"
    var energy = 0.0
    var summaries: [[String:Any]] = []
    var savedSummaryCount = 0
    var powerHistory: [[String:Any]] = []
    var powerSum = 0.0
    var powerCount = 0
    var lastSummary = Date()
    var logLines: [String] = []
    var lastPublish = Date.distantPast
    var lastWebhook = Date.distantPast
    var webhookInFlight = false
    var webhookTask: URLSessionDataTask?
    var sessionID = UUID().uuidString
    lazy var webhookSession: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil; settings.urlCache = nil
        return URLSession(configuration:settings,delegate:NoRedirectDelegate(),delegateQueue:nil)
    }()

    override init() {
        super.init()
        timer = Timer(timeInterval:0.5,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!,forMode:.common); RunLoop.main.add(timer!,forMode:.modalPanel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        let u = navigationAction.request.url
        decisionHandler(u?.isFileURL == true || u?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit(["event":"ready", "config": object(config), "interfaces": interfaces()]); publish()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String:Any], let action = body["action"] as? String else { return }
        do {
            if ["demo","importCSV","importBIN"].contains(action), let input = body["config"] as? [String:Any] {
                guard connection == nil && listener == nil else { throw MeterError.invalid("请先断开设备，再使用离线功能") }
                let cfg = try JSONDecoder().decode(MeterConfig.self,from:JSONSerialization.data(withJSONObject:input)); try cfg.validate(); config = cfg
            }
            switch action {
            case "start":
                guard let input = body["config"] as? [String:Any] else { throw MeterError.invalid("缺少连接配置") }
                let cfg = try JSONDecoder().decode(MeterConfig.self, from: JSONSerialization.data(withJSONObject: input)); try cfg.validate()
                start(cfg)
            case "disconnect": disconnect(); publish()
            case "query":
                guard connected else { throw MeterError.invalid("请先建立 TCP 连接") }
                if config.protocolName == "ys8000" { if collecting { throw MeterError.invalid("请先停止采集，再查询配置") }; textQueryUntil = Date().addingTimeInterval(3); send(Data("ifconfig".utf8)); log("发送配置查询 ifconfig") }
                else { send(Data([1,4,0,0,0,0x50,0x55,0xaa])); log("发送原机单相参数读取请求（0x04）") }
            case "begin":
                guard connected else { throw MeterError.invalid("请先建立 TCP 连接") }
                if config.protocolName == "ys8000" {
                    guard (try hexBytes(config.headerHex)).count == 3, (try hexBytes(config.trailerHex)).count == 3 else { throw MeterError.invalid("YS8000 连续解析需填写已经核对的 3 字节帧头和帧尾；可先使用短时抓包") }
                    send(Data("#".utf8))
                }
                collecting = true; stoppedByUser = false; textQueryUntil = nil; log("开始接收波形；iSocket 模式依赖设备主动推送")
            case "stop": stopCollection(); publish()
            case "capture":
                guard connected else { throw MeterError.invalid("请先建立 TCP 连接") }
                raw = Data(); stoppedByUser = false; captureUntil = Date().addingTimeInterval(3)
                if config.protocolName == "ys8000" { send(Data("#".utf8)); collecting = true }
                log("开始 3 秒原始抓包，最多保留 2 MiB")
            case "demo": if confirmDiscard() { disconnect(); resetData(); mode = "demo"; source = "模拟演示 · 非实测"; demoWave(); log("离线演示已开启，没有连接设备") }
            case "importCSV": try readCSV()
            case "importBIN": try readBinary()
            case "exportWave": try saveWave()
            case "exportSummary": try saveSummary()
            case "exportRaw": try saveRaw()
            case "exportDiagnostic": try saveDiagnostic()
            case "saveConfig": try saveConfigFile(body)
            case "loadConfig": try loadConfigFile()
            default: break
            }
        } catch { log("操作未完成：\(error.localizedDescription)"); emit(["event":"error", "message":error.localizedDescription]) }
        publish()
    }

    func start(_ cfg: MeterConfig) {
        guard confirmDiscard() else { return }
        disconnect(); config = cfg; resetData(); mode = "live"; source = "设备采集 · 参考系数未标定"
        decoder = FrameDecoder(cfg, expectRegistration: cfg.transport == "server" && cfg.protocolName == "isocket" && cfg.registration)
        generation += 1; let token = generation
        if cfg.transport == "client" {
            let conn = NWConnection(host: NWEndpoint.Host(cfg.host), port: NWEndpoint.Port(rawValue: UInt16(cfg.port))!, using: .tcp)
            connection = conn; log("连接 \(cfg.host):\(cfg.port)（\(cfg.protocolName)）"); activate(conn, token: token)
            DispatchQueue.main.asyncAfter(deadline: .now()+6) { [weak self, weak conn] in
                guard let self = self, self.generation == token, !self.connected else { return }
                conn?.cancel(); self.connection = nil; self.log("连接超时：核对设备 Wi-Fi、IP 和端口"); self.publish()
            }
        } else {
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(cfg.bindIP), port: NWEndpoint.Port(rawValue: UInt16(cfg.port))!)
                let server = try NWListener(using: parameters)
                listener = server
                server.stateUpdateHandler = { [weak self] state in
                    guard let self = self, self.generation == token else { return }
                    if case .ready = state { self.log("TCP 监听已就绪：\(cfg.bindIP):\(cfg.port)，等待设备主动连接") }
                    if case .failed(let e) = state { self.log("监听失败：\(e.localizedDescription)"); self.listener = nil }
                    self.publish()
                }
                server.newConnectionHandler = { [weak self] conn in
                    guard let self = self, self.generation == token else { conn.cancel(); return }
                    guard self.connection == nil else { conn.cancel(); self.log("已占用一台设备连接，本次新增连接已关闭"); return }
                    self.connection = conn
                    self.energy = 0; self.powerSum = 0; self.powerCount = 0; self.lastData = nil; self.lastMetrics = nil; self.lastFrame = MeterFrame(); self.powerHistory = []; self.sessionID = UUID().uuidString
                    self.decoder = FrameDecoder(cfg, expectRegistration: cfg.protocolName == "isocket" && cfg.registration)
                    self.log("设备已接入：\(conn.endpoint)"); self.activate(conn, token: token)
                }
                server.start(queue: .main)
                if cfg.discovery { try startDiscovery(cfg, token: token) }
            } catch { log("无法启动本地监听：\(error.localizedDescription)"); disconnect() }
        }
        publish()
    }

    func activate(_ conn: NWConnection, token: Int) {
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, self.generation == token, self.connection === conn else { return }
            switch state {
            case .ready: self.connected = true; self.log("TCP 已连接，尚需收到有效测量帧"); self.receive(conn, token: token)
            case .failed(let error): self.log("TCP 错误：\(error.localizedDescription)"); self.connected = false; self.collecting = false; self.connection = nil; conn.cancel()
            case .cancelled: self.connected = false; self.collecting = false
            default: break
            }
            self.publish()
        }
        conn.start(queue: .main)
    }

    func startDiscovery(_ cfg: MeterConfig, token: Int) throws {
        let p = NWParameters.udp
        p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(cfg.bindIP),port: NWEndpoint.Port(rawValue: 8266)!)
        let udp = try NWListener(using: p); discoveryListener = udp
        udp.stateUpdateHandler = { [weak self] state in if case .failed(let e) = state { self?.log("UDP 设备发现不可用：\(e.localizedDescription)") } }
        udp.newConnectionHandler = { [weak self] conn in
            guard let self = self, self.generation == token else { conn.cancel(); return }
            if self.discoveryPeers.count >= 16 { conn.cancel(); return }
            self.discoveryPeers.append(conn); conn.start(queue: .main)
            conn.receiveMessage { [weak self, weak conn] data,_,_,_ in
                guard let self = self, let conn = conn, self.generation == token else { conn?.cancel(); return }
                if data == Data("searchServer".utf8) {
                    let response = try? JSONSerialization.data(withJSONObject: ["ServerIP":cfg.bindIP])
                    conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
                    self.log("已回应设备发现请求（原机 UDP 8266）")
                } else { conn.cancel() }
                self.discoveryPeers.removeAll { $0 === conn }
            }
            DispatchQueue.main.asyncAfter(deadline: .now()+3) { [weak self, weak conn] in
                guard let conn = conn else { return }; conn.cancel(); self?.discoveryPeers.removeAll { $0 === conn }
            }
        }
        udp.start(queue: .main); log("开启原机设备发现回应：仅监听所选本机 IP 的 UDP 8266")
    }

    func receive(_ conn: NWConnection, token: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data,_,finished,error in
            guard let self = self, let conn = conn, self.generation == token, self.connection === conn else { return }
            if let data = data, !data.isEmpty {
                self.bytesReceived += data.count
                self.raw.append(data)
                if self.raw.count > 2_097_152 { self.raw.removeFirst(self.raw.count-2_097_152) }
                if let until = self.textQueryUntil, Date() < until, let text = String(data:data,encoding:.utf8) {
                    let safe = text.replacingOccurrences(of: "(?i)(pwd|password|pass|token|key)\\s*[:=]\\s*[^\\s,;]+", with: "$1:***", options: .regularExpression)
                    self.log("配置回复："+String(safe.prefix(600)))
                } else {
                    for frame in self.decoder.feed(data) { self.consume(frame) }
                }
                if Date().timeIntervalSince(self.lastPublish) > 0.25 { self.publish() }
            }
            if finished || error != nil {
                self.connected = false; self.collecting = false; self.connection = nil
                self.loadState = LoadState(); self.log("设备连接已结束，未收到的时段不补算电量"); self.publish(); conn.cancel()
            } else { self.receive(conn, token: token) }
        }
    }

    func consume(_ f: MeterFrame) {
        if !f.registers.isEmpty {
            guard f.registers.count >= 11 else { log("参数帧不足 11 个寄存器，未解释电气指标"); return }
            let r = f.registers
            let vs = 0.02452, cs = 0.00257, ps = vs*cs*4096
            hardware = ["voltage":Double(r[0])*vs,"current":Double(r[1])*cs,"power":Double(r[2])*ps,"reactive":Double(r[3])*ps,"pf":Double(r[4])*0.01,"frequency":Double(r[9])*0.01,"energyRegister":Double(UInt32(UInt16(bitPattern:r[5]))*65536+UInt32(UInt16(bitPattern:r[6])))*ps*0.001]
            lastData = Date(); log("收到参数帧 \(f.registers.count) 个寄存器；\(f.integrity)。原机系数仍需实测标定")
            return
        }
        do {
            let m = try analyze(f.voltage,f.current,rate:config.sampleRate,lineHz:config.lineHz)
            lastFrame = f; lastMetrics = m; lastData = Date(); collecting = mode == "live" && !stoppedByUser
            if mode == "live" && !stoppedByUser { source = config.calibrated ? "设备采集 · 操作者确认标定" : "设备采集 · 参考系数未标定"; powerSum += m.powerW; powerCount += 1
                if config.calibrated && m.powerW >= 0 { energy += m.powerW*m.durationS/3_600_000 }
            }
        } catch { log("波形未采用：\(error.localizedDescription)") }
    }

    func send(_ data: Data) { connection?.send(content:data,completion:.contentProcessed { [weak self] e in if let e = e { DispatchQueue.main.async { self?.log("发送失败：\(e.localizedDescription)") } } }) }
    func stopCollection() {
        if connected && config.protocolName == "ys8000" { send(Data("$".utf8)) }
        stoppedByUser = true; collecting = false; captureUntil = nil; powerSum = 0; powerCount = 0
        if config.protocolName == "isocket" { disconnect(); log("已停止并断开连接（原机主动推送协议）") } else { log("已发送 $，停止本机采集") }
    }
    func disconnect() {
        if connected && config.protocolName == "ys8000" { send(Data("$".utf8)) }
        generation += 1; connection?.cancel(); connection = nil; listener?.cancel(); listener = nil
        discoveryListener?.cancel(); discoveryListener = nil; discoveryPeers.forEach { $0.cancel() }; discoveryPeers.removeAll()
        webhookTask?.cancel(); webhookTask = nil; webhookInFlight = false
        powerSum = 0; powerCount = 0
        connected = false; collecting = false; captureUntil = nil; textQueryUntil = nil; loadState = LoadState()
    }
    func resetData() {
        decoder = FrameDecoder(config)
        raw = Data(); bytesReceived = 0; lastData = nil; lastMetrics = nil; hardware = [:]; lastFrame = MeterFrame(); energy = 0
        summaries = []; savedSummaryCount = 0; powerHistory = []; powerCount = 0; powerSum = 0; loadState = LoadState(); lastSummary = Date(); stoppedByUser = false; sessionID = UUID().uuidString
    }
    func tick() {
        if mode == "demo" { demoWave() }
        if let until = captureUntil, Date() >= until { captureUntil = nil; if config.protocolName == "ys8000" { stopCollection() }; log("短时抓包结束：保留 \(raw.count) 字节，可导出原始 BIN") }
        if Date().timeIntervalSince(lastSummary) >= 1 {
            if mode == "live", powerCount > 0, let m = lastMetrics {
                let p = powerSum/Double(powerCount), time = ISO8601DateFormatter().string(from:Date())
                let state = loadState.update(power:p,now:Date(),config:config)
                var row: [String:Any] = ["timestamp":time,"device_id":decoder.deviceID.isEmpty ? "meter-01" : decoder.deviceID,"power_w":p,"voltage_rms":m.voltageRMS,"current_rms":m.currentRMS,"source":"mac_\(config.protocolName)","session_id":sessionID,"sample_rate_hz":config.sampleRate,"calibrated":config.calibrated,"load_state":state,"energy_basis":"captured_waveform_integral"]
                row["energy_kwh"] = config.calibrated ? energy : NSNull()
                summaries.append(row); if summaries.count > 86400 { summaries.removeFirst(summaries.count-86400) }
                powerHistory.append(["power":p,"time":time]); if powerHistory.count > 180 { powerHistory.removeFirst() }
                pushWebhook(row)
                powerSum = 0; powerCount = 0
            }
            lastSummary = Date()
        }
        if mode == "live", let last = lastData, Date().timeIntervalSince(last) > 5 { loadState = LoadState() }
        publish()
    }

    func pushWebhook(_ row: [String:Any]) {
        guard mode == "live", config.webhookEnabled, !webhookInFlight, Date().timeIntervalSince(lastWebhook) >= config.webhookInterval, let url = URL(string:config.webhook) else { return }
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.httpBody = try? JSONSerialization.data(withJSONObject:row)
        webhookInFlight = true; lastWebhook = Date(); let token = generation
        webhookTask = webhookSession.dataTask(with:request) { [weak self] _,response,error in DispatchQueue.main.async {
            guard let self = self, self.generation == token else { return }; self.webhookInFlight = false
            if let error = error { self.log("Webhook 未送达：\(error.localizedDescription)（本地记录保留，未自动重发）") }
            else if let r = response as? HTTPURLResponse, !(200...299).contains(r.statusCode) { self.log("Webhook 返回 HTTP \(r.statusCode)") }
        } }; webhookTask?.resume()
    }

    func demoWave() {
        let count = 640, rate = config.sampleRate, shift = Date().timeIntervalSince1970.truncatingRemainder(dividingBy:10), amps = 1.6+sin(shift)*0.2
        let v = (0..<count).map { 230*sqrt(2)*sin(2*Double.pi*config.lineHz*Double($0)/rate) }
        let i = (0..<count).map { amps*sqrt(2)*(sin(2*Double.pi*config.lineHz*Double($0)/rate-0.2)+0.08*sin(2*Double.pi*config.lineHz*3*Double($0)/rate)) }
        lastFrame = MeterFrame(voltage:v,current:i,integrity:"合成波形")
        lastMetrics = try? analyze(v,i,rate:rate,lineHz:config.lineHz); lastData = Date()
    }

    func status() -> String {
        if mode == "demo" { return "离线演示" }; if mode == "file" { return "离线文件" }
        if connected {
            if stoppedByUser { return "TCP 已连接 · 采集已停止" }
            guard let last = lastData else { return bytesReceived > 0 ? "已收字节 · 尚无有效帧" : "TCP 已连接 · 等待数据" }
            return Date().timeIntervalSince(last) > 5 ? "数据中断" : "正在接收"
        }
        return listener != nil ? "监听中 · 等待设备" : "未连接"
    }
    func publish() {
        lastPublish = Date()
        var packet: [String:Any] = ["event":"state","mode":mode,"status":status(),"source":source,"connected":connected,"listening":listener != nil,"collecting":collecting,"bytes":bytesReceived,"goodFrames":decoder.goodFrames,"badFrames":decoder.badFrames,"discarded":decoder.discardedBytes,"deviceID":decoder.deviceID,"logs":logLines,"rawBytes":raw.count,"rows":summaries.count,"history":powerHistory,"hardware":hardware,"calibrated":config.calibrated,"loadState":mode == "live" && connected && collecting && lastData.map({Date().timeIntervalSince($0)<=5}) == true ? loadState.state : "未知 / 非实时","energy":config.calibrated && mode == "live" ? energy : NSNull(),"integrity":lastFrame.integrity]
        packet["timestamp"] = lastData.map { ISO8601DateFormatter().string(from:$0) } ?? ""
        if let m = lastMetrics { packet["metrics"] = object(m) }
        packet["voltage"] = Array(lastFrame.voltage.prefix(640)); packet["current"] = Array(lastFrame.current.prefix(640))
        emit(packet)
    }
    func log(_ s: String) { let time = DateFormatter(); time.dateFormat = "HH:mm:ss"; logLines.append("[\(time.string(from:Date()))] \(s)"); if logLines.count > 120 { logLines.removeFirst() } }
    func emit(_ packet: [String:Any]) {
        guard JSONSerialization.isValidJSONObject(packet), let data = try? JSONSerialization.data(withJSONObject:packet,options:[.sortedKeys]), let json = String(data:data,encoding:.utf8) else { return }
        web?.evaluateJavaScript("window.receive && window.receive(\(json));",completionHandler:nil)
    }
    func object<T: Encodable>(_ v: T) -> Any { (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(v))) ?? [:] }

    func choose(_ extensions: [String]) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension:$0) }; return panel.runModal() == .OK ? panel.url : nil
    }
    @discardableResult func write(_ data: Data, name: String, ext: String) throws -> Bool {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension:ext) ?? .data]
        if panel.runModal() == .OK, let url = panel.url { try data.write(to:url,options:.atomic); log("已保存：\(url.lastPathComponent)"); return true }
        return false
    }
    func confirmDiscard() -> Bool {
        guard summaries.count > savedSummaryCount else { return true }
        let alert = NSAlert(); alert.messageText = "采集摘要尚未全部导出"
        alert.informativeText = "本次记录暂存在内存。继续将丢弃未导出的摘要；请取消后点击“导出真实摘要”保存。"
        alert.addButton(withTitle:"取消，返回保存"); alert.addButton(withTitle:"继续，丢弃未导出记录")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func readCSV() throws {
        guard let url = choose(["csv"]) else { return }; let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size <= 32_000_000 else { throw MeterError.invalid("CSV 文件最大 32 MB") }
        let waves = try parseWaveCSV(String(contentsOf:url,encoding:.utf8)), metrics = try analyze(waves.0,waves.1,rate:config.sampleRate,lineHz:config.lineHz)
        guard confirmDiscard() else { return }
        disconnect(); resetData(); mode = "file"; source = "CSV 离线分析 · \(url.lastPathComponent)"
        lastFrame = MeterFrame(voltage:waves.0,current:waves.1,integrity:"CSV，标定来源由文件提供者确认"); lastMetrics = metrics; lastData = Date()
        log("导入 \(waves.0.count) 对波形。仅本机分析，不标记为设备在线")
    }
    func readBinary() throws {
        guard let url = choose(["bin","dat"]) else { return }
        let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size <= 16_777_216 else { throw MeterError.invalid("BIN 文件最大 16 MiB") }
        let data = try Data(contentsOf:url)
        let d = FrameDecoder(config,expectRegistration:config.transport == "server" && config.registration && config.protocolName == "isocket")
        let frames = d.feed(data); guard frames.count > 0 else { throw MeterError.invalid("未解析出有效帧：核对协议、注册头和帧配置。原始文件未修改") }
        guard confirmDiscard() else { return }
        disconnect(); resetData(); mode = "file"; source = "BIN 离线回放 · \(url.lastPathComponent)"; decoder = d; raw = Data(data.suffix(2_097_152)); bytesReceived = data.count
        for f in frames.suffix(1) { consume(f) }; log("回放 \(d.goodFrames) 帧，校验失败 \(d.badFrames) 次；显示最后一帧")
    }
    func saveWave() throws {
        guard !lastFrame.voltage.isEmpty else { throw MeterError.invalid("没有可导出的波形") }
        var text = "I,V,label\r\n"
        for (v,i) in zip(lastFrame.voltage,lastFrame.current) { text += "\(i),\(v),\(mode == "demo" ? "simulation" : mode == "file" ? "offline" : "live")\r\n" }
        try write(Data(text.utf8),name:"\(mode)-波形.csv",ext:"csv")
    }
    func saveSummary() throws {
        guard !summaries.isEmpty else { throw MeterError.invalid("暂无真实采集摘要；模拟演示不会写入真实记录") }
        let snapshotCount = summaries.count
        let keys = ["device_id","timestamp","power_w","energy_kwh","voltage_rms","current_rms","load_state","sample_rate_hz","calibrated","energy_basis","source","session_id"]
        var text = "\u{feff}"+keys.joined(separator:",")+"\r\n"
        for row in summaries { text += keys.map { key in let v = row[key]; let s = v == nil || v is NSNull ? "" : String(describing:v!); return "\""+s.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }.joined(separator:",")+"\r\n" }
        if try write(Data(text.utf8),name:"真实采集摘要.csv",ext:"csv") { savedSummaryCount = snapshotCount }
    }
    func saveRaw() throws { guard !raw.isEmpty else { throw MeterError.invalid("暂无原始报文") }; try write(raw,name:"\(mode)-原始抓包.bin",ext:"bin") }
    func saveDiagnostic() throws {
        // Do not include webhook URLs or unredacted configuration responses.
        let packet: [String:Any] = ["app":"Green Meter Mac","version":"1.0.0","source":source,"status":status(),"protocol":config.protocolName,"sample_rate_configured":config.sampleRate,"calibrated":config.calibrated,"device_id":decoder.deviceID,"bytes_received":bytesReceived,"valid_frames":decoder.goodFrames,"invalid_frames":decoder.badFrames,"discarded_bytes":decoder.discardedBytes,"integrity":lastFrame.integrity,"metrics":lastMetrics.map{object($0)} ?? [:],"hardware":hardware,"captured_points":lastFrame.voltage.count,"notes":"协议来源于用户提供的 C# 源码；未经实物联调不能确认设备兼容、采样率或标定。"]
        try write(JSONSerialization.data(withJSONObject:packet,options:[.prettyPrinted,.sortedKeys]),name:"设备诊断.json",ext:"json")
    }
    func saveConfigFile(_ body: [String:Any]) throws {
        guard let input = body["config"] as? [String:Any] else { return }
        let cfg = try JSONDecoder().decode(MeterConfig.self,from:JSONSerialization.data(withJSONObject:input)); try cfg.validate()
        try write(JSONEncoder().encode(cfg),name:"Mac电表配置.json",ext:"json")
    }
    func loadConfigFile() throws {
        guard connection == nil && listener == nil else { throw MeterError.invalid("请先断开连接再加载配置") }
        guard let url = choose(["json"]) else { return }
        let data = try Data(contentsOf:url); guard data.count <= 65536 else { throw MeterError.invalid("配置文件过大") }
        let cfg = try JSONDecoder().decode(MeterConfig.self,from:data); try cfg.validate(); config = cfg
        emit(["event":"config", "config":object(cfg)]); log("配置已载入，尚未连接设备")
    }
    func interfaces() -> [[String:String]] {
        var out: [[String:String]] = [["name":"本机回环（仅测试）","ip":"127.0.0.1"]]
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return out }; defer { freeifaddrs(ptr) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let p = node {
            defer { node = p.pointee.ifa_next }
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(a,socklen_t(a.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {
                let ip = String(cString:host); if ip != "127.0.0.1" { out.append(["name":String(cString:p.pointee.ifa_name),"ip":ip]) }
            }
        }
        return out
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let controller = MeterController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle:"关于绿电实验室",action:#selector(about),keyEquivalent:"")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"退出绿电实验室",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = appMenu; menu.addItem(item)
        let editItem = NSMenuItem(title:"编辑",action:nil,keyEquivalent:""), edit = NSMenu(title:"编辑")
        for (title,action,key) in [("撤销",Selector(("undo:")),"z"),("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:action,keyEquivalent:key) }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        let settings = WKWebViewConfiguration(); settings.userContentController.add(controller,name:"meter")
        let web = WKWebView(frame:.zero,configuration:settings); web.navigationDelegate = controller; controller.web = web
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1250,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "绿电实验室 · Mac 电表监测"; window.minSize = NSSize(width:950,height:680); window.contentView = web
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if let url = Bundle.main.url(forResource:"index",withExtension:"html") { web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
    }
    @objc func about() { let a = NSAlert(); a.messageText = "绿电实验室 Mac 电表监测 1.0"; a.informativeText = "基于用户提供的 iSocket C# 协议移植。原生 Apple Silicon / Intel 应用，离线运行。实物通信与标定待验证。"; a.runModal() }
    func applicationWillTerminate(_ notification: Notification) { controller.disconnect() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { controller.confirmDiscard() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
