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
    var fileCaptureDate: Date?
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
    let recorder: SessionRecorder
    let enableDrive: Bool
    let mirrorQueue = DispatchQueue(label:"greenmeter.drive-mirror",qos:.utility)
    var mirrorBusy = false
    var mirrorMessage = "等待 Google Drive 桌面端"
    var mirrorPending = 0
    var mirrorCopied = 0
    var storageError = ""
    var retry = ReconnectSchedule()
    var reconnectAt: Date?
    var wantsConnection = false
    var retryDate: Date?
    var connectionBegan = Date()
    var receivedSinceReady: Date?
    var deviceCommandBusy = false
    var lastDeviceCommandAt = Date.distantPast
    var deviceCommandMessage = "尚未发送指令 · 输出供电状态未核实"
    var receivedRate: Double?
    var rateStart: Date?
    var ratePoints = 0
    var rawSquaresV = 0.0, rawSquaresI = 0.0
    var rawWindowPoints = 0
    var nextMirror = Date.distantPast
    var sampleLabel = ""
    var lastQualityLog = Date.distantPast
    var lastStats: [String:Double] = [:]
    var lastReferencePower: ReferencePower?
    var referencePowerWindow = PowerWindow()
    var referencePowerRows: [[String:Any]] = []
    var referencePowerHistory: [[String:Any]] = []
    var referencePowerError = ""
    var storedDriveFolder: URL? {
        UserDefaults.standard.string(forKey:"greenmeter.driveFolder").map { URL(fileURLWithPath:$0,isDirectory:true) }
    }
    lazy var webhookSession: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil; settings.urlCache = nil
        return URLSession(configuration:settings,delegate:NoRedirectDelegate(),delegateQueue:nil)
    }()

    init(storageRoot: URL = SessionRecorder.defaultRoot, enableDrive: Bool = true) {
        self.recorder = SessionRecorder(root:storageRoot); self.enableDrive = enableDrive
        super.init()
        if let data = try? Data(contentsOf:storageRoot.appendingPathComponent("reference-power-settings.json")),
           let saved = try? JSONDecoder().decode(MeterConfig.self,from:data),saved.host == config.host,
           saved.port == config.port,saved.protocolName == config.protocolName,(try? saved.validate()) != nil {
            config.voltageScale = saved.voltageScale;config.currentScale = saved.currentScale
            config.voltageOffset = saved.voltageOffset;config.currentOffset = saved.currentOffset;config.currentSign = saved.currentSign
        }
        do { let recovered = try recorder.recoverInterrupted(); if recovered > 0 { log("已恢复 \(recovered) 个上次未正常结束的保存会话") } }
        catch { storageError = error.localizedDescription; log("自动保存恢复检查："+error.localizedDescription) }
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
                sampleLabel = String((body["sampleLabel"] as? String ?? "").prefix(80)); try start(cfg)
            case "disconnect": disconnect(); publish()
            case "fitReferencePower": try applyReferencePower(body)
            case "exportPower": try savePowerReadings()
            case "deviceCommand":
                guard let command = DeviceCommand(rawValue:body["command"] as? String ?? ""),
                      let encoding = DeviceCommandEncoding(rawValue:body["commandEncoding"] as? String ?? "") else { throw MeterError.invalid("无效的设备指令或编码") }
                try sendDeviceCommand(command,encoding:encoding)
            case "query":
                guard connected else { throw MeterError.invalid("请先建立 TCP 连接") }
                guard config.protocolName != "socket128" else { throw MeterError.invalid("本次插座连接后主动发送，不需要查询指令") }
                if config.protocolName == "ys8000" { if collecting { throw MeterError.invalid("请先停止采集，再查询配置") }; textQueryUntil = Date().addingTimeInterval(3); send(Data("ifconfig".utf8)); log("发送配置查询 ifconfig") }
                else { send(Data([1,4,0,0,0,0x50,0x55,0xaa])); log("发送原机单相参数读取请求（0x04）") }
            case "begin":
                guard connected else { throw MeterError.invalid("请先建立 TCP 连接") }
                if ["ys8000","socket128"].contains(config.protocolName) { try sendDeviceCommand(.startData,encoding:.singleByte) }
                else { collecting = true; stoppedByUser = false; textQueryUntil = nil; log("开始本机波形解析") }
            case "stop":
                if ["ys8000","socket128"].contains(config.protocolName) { try sendDeviceCommand(.stopData,encoding:.singleByte) }
                else { stopCollection() }; publish()
            case "capture":
                guard connected else { throw MeterError.invalid("请先建立 TCP 连接") }
                raw = Data(); stoppedByUser = false; captureUntil = Date().addingTimeInterval(3)
                if config.protocolName == "ys8000" { send(Data("#".utf8)); collecting = true }
                log("开始 3 秒原始抓包，最多保留 2 MiB")
            case "demo": if confirmDiscard() { disconnect(); resetData(); mode = "demo"; source = "模拟演示 · 非实测"; demoWave(); log("离线演示已开启，没有连接设备") }
            case "importCSV": try readCSV()
            case "importBIN": try readBinary()
            case "replayCapture":
                guard connection == nil && listener == nil else { throw MeterError.invalid("请先断开设备再回放实测文件") }
                guard let url = Bundle.main.url(forResource:"F251D351-实测原始",withExtension:"bin") else { throw MeterError.invalid("未找到随应用保存的实测文件") }
                try loadBinary(url,capture:true)
            case "chooseDrive":
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                panel.message = "请选择 Google Drive 中“绿电实验室/采集数据”同步文件夹"
                if panel.runModal() == .OK, let url = panel.url {
                    guard url.path != recorder.root.path, !url.path.hasPrefix(recorder.root.path+"/") else { throw MeterError.invalid("Drive 目录不能是本地采集目录或其子目录") }
                    UserDefaults.standard.set(url.path,forKey:"greenmeter.driveFolder"); syncDrive()
                }
            case "syncDrive": syncDrive()
            case "openRecords": NSWorkspace.shared.open(recorder.root)
            case "openDrive": NSWorkspace.shared.open(URL(string:"https://drive.google.com/drive/folders/1P_CWJQR54a0jF4tK4te3zm2XNRov-6b1")!)
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

    func start(_ cfg: MeterConfig) throws {
        guard confirmDiscard() else { return }
        disconnect()
        guard storageError.isEmpty else { throw MeterError.invalid("自动保存不可用："+storageError) }
        config = cfg; resetData()
        try recorder.start(config:cfg); sessionID = recorder.session
        try recorder.event("sample_annotation",details:["operator_label":sampleLabel,"label_source":"user_entered_NOT_model_prediction"])
        mode = "live"; source = "设备采集 · 原始 ADC（待标定）"
        wantsConnection = true; retry.reset(); reconnectAt = nil
        decoder = FrameDecoder(cfg, expectRegistration: cfg.transport == "server" && cfg.protocolName == "isocket" && cfg.registration)
        generation += 1; let token = generation
        if cfg.transport == "client" {
            connectClient(token:token)
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
                    self.energy = 0; self.powerSum = 0; self.powerCount = 0; self.lastData = nil; self.lastMetrics = nil; self.lastFrame = MeterFrame(); self.powerHistory = []
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
            case .ready:
                self.connected = true; self.connectionBegan = Date(); self.receivedSinceReady = nil
                self.deviceCommandMessage = "TCP 已连接 · 输出供电状态未核实；指令仅在点击时发送"
                self.log("TCP 已连接，等待有效帧；原始数据会自动落盘")
                self.receive(conn, token: token)
            case .failed(let error): self.connectionLost(conn,reason:error.localizedDescription,token:token)
            case .cancelled: self.connected = false; self.collecting = false
            case .waiting(let error): self.log("网络暂不可用："+error.localizedDescription)
            default: break
            }
            self.publish()
        }
        conn.start(queue: .main)
    }

    func connectClient(token: Int) {
        guard wantsConnection, generation == token, connection == nil else { return }
        connectionBegan = Date(); lastData = nil; loadState = LoadState()
        let conn = NWConnection(host:NWEndpoint.Host(config.host),port:NWEndpoint.Port(rawValue:UInt16(config.port))!,using:.tcp)
        connection = conn; log("连接 \(config.host):\(config.port)；失败后自动重试，停止按钮可取消")
        activate(conn,token:token)
        DispatchQueue.main.asyncAfter(deadline:.now()+8) { [weak self,weak conn] in
            guard let self = self, let conn = conn, self.generation == token, self.connection === conn, !self.connected else { return }
            self.connectionLost(conn,reason:"连接超时，核对插座 Wi-Fi 与地址",token:token); self.publish()
        }
    }
    func connectionLost(_ conn: NWConnection, reason: String, token: Int) {
        guard generation == token, connection === conn else { return }
        connection = nil; connected = false; collecting = false; conn.cancel()
        referencePowerWindow.reset();referencePowerHistory = []
        deviceCommandBusy = false; deviceCommandMessage = "连接已中断 · 输出供电状态未核实；控制指令不自动重发"
        powerCount = 0; powerSum = 0; rawWindowPoints = 0; rawSquaresV = 0; rawSquaresI = 0
        loadState = LoadState(); rateStart = nil; ratePoints = 0; receivedRate = nil; powerHistory = []
        let replacement = FrameDecoder(config)
        replacement.goodFrames = decoder.goodFrames; replacement.badFrames = decoder.badFrames
        replacement.discardedBytes = decoder.discardedBytes+decoder.buffer.count
        decoder = replacement
        log("连接中断："+reason+"；缺失时段不补算电量")
        if wantsConnection && config.transport == "client" && storageError.isEmpty {
            let delay = retry.nextDelay(); reconnectAt = Date().addingTimeInterval(delay)
            log("将在 \(Int(delay)) 秒后重连")
        }
    }
    func failStorage(_ error: Error) {
        guard storageError.isEmpty else { return }
        storageError = error.localizedDescription; wantsConnection = false; reconnectAt = nil
        connection?.cancel(); connection = nil; connected = false; collecting = false
        log("自动保存失败，采集已暂停："+storageError)
        emit(["event":"error","message":"自动保存失败，已暂停采集并保留现有文件："+storageError])
    }
    func syncDrive() {
        guard enableDrive else { return }
        guard !mirrorBusy else { return }; mirrorBusy = true
        let selectedDestination = storedDriveFolder, root = recorder.root
        mirrorQueue.async { [weak self] in
            do {
                let destination = selectedDestination ?? DriveMirror.detectedDestination()
                let result = try DriveMirror(source:root).sync(to:destination)
                DispatchQueue.main.async { self?.mirrorBusy = false; self?.mirrorMessage = result.message; self?.mirrorPending = result.pending; self?.mirrorCopied += result.copied; self?.publish() }
            } catch {
                DispatchQueue.main.async { self?.mirrorBusy = false; self?.mirrorMessage = "同步暂不可用，本地文件保留："+error.localizedDescription; self?.publish() }
            }
        }
    }
    func finishForQuit(_ done: @escaping () -> Void) {
        disconnect()
        let root = recorder.root, selectedDestination = storedDriveFolder
        guard enableDrive else { done(); return }
        // Drain closed local files before quitting; cloud transport remains Drive's job.
        mirrorQueue.async {
            let target = selectedDestination ?? DriveMirror.detectedDestination()
            _ = try? DriveMirror(source:root).sync(to:target)
            DispatchQueue.main.async { done() }
        }
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
                do { try self.recorder.appendRaw(data) } catch { self.failStorage(error); return }
                self.receivedSinceReady = Date()
                self.bytesReceived += data.count
                self.raw.append(data)
                if self.raw.count > 2_097_152 { self.raw.removeFirst(self.raw.count-2_097_152) }
                if let until = self.textQueryUntil, Date() < until, let text = String(data:data,encoding:.utf8) {
                    let safe = text.replacingOccurrences(of: "(?i)(pwd|password|pass|token|key)\\s*[:=]\\s*[^\\s,;]+", with: "$1:***", options: .regularExpression)
                    self.log("配置回复："+String(safe.prefix(600)))
                } else {
                    let before = self.decoder.discardedBytes
                    for frame in self.decoder.feed(data) { self.consume(frame) }
                    if self.decoder.discardedBytes > before {
                        self.rateStart = nil; self.ratePoints = 0
                        if Date().timeIntervalSince(self.lastQualityLog) >= 2 {
                            self.lastQualityLog = Date()
                            self.log("帧重新定位：累计跳过 \(self.decoder.discardedBytes) 字节；缺失内容不补算")
                        }
                    }
                }
                if Date().timeIntervalSince(self.lastPublish) > 0.25 { self.publish() }
            }
            if finished || error != nil {
                self.connectionLost(conn,reason:error?.localizedDescription ?? "设备关闭连接",token:token); self.publish()
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
            let m = try f.rawSamples ? analyzeRaw(f.voltage,f.current,rate:config.sampleRate) : analyze(f.voltage,f.current,rate:config.sampleRate,lineHz:config.lineHz)
            lastFrame = f; lastMetrics = m; lastData = Date(); collecting = mode == "live" && !stoppedByUser
            lastReferencePower = nil;referencePowerError = ""
            if f.rawSamples {
                do {
                    lastReferencePower = try referencePower(f.voltage,f.current,config:config)
                    if mode == "live",!stoppedByUser,let watts = lastReferencePower {
                        referencePowerWindow.append(watts.powerW,points:watts.count)
                    }
                } catch { referencePowerError = error.localizedDescription }
            }
            if mode == "live" {
                retry.reset(); reconnectAt = nil
                if rateStart == nil { rateStart = Date(); ratePoints = 0 }
                ratePoints += f.voltage.count
                if let began = rateStart, Date().timeIntervalSince(began) >= 5 {
                    receivedRate = Double(ratePoints)/Date().timeIntervalSince(began); rateStart = Date(); ratePoints = 0
                }
                let av = f.rawSamples ? f.voltage : f.voltageADC, ai = f.rawSamples ? f.current : f.currentADC
                if !av.isEmpty, av.count == ai.count {
                    let n = Double(av.count), vm = av.reduce(0,+)/n, im = ai.reduce(0,+)/n
                    lastStats = ["voltageMeanADC":vm,"currentMeanADC":im,
                        "voltageACRMS":sqrt(av.reduce(0){$0+($1-vm)*($1-vm)}/n),
                        "currentACRMS":sqrt(ai.reduce(0){$0+($1-im)*($1-im)}/n)]
                }
                if f.rawSamples && !stoppedByUser { rawSquaresV += m.voltageRMS*m.voltageRMS*Double(m.count); rawSquaresI += m.currentRMS*m.currentRMS*Double(m.count); rawWindowPoints += m.count }
            }
            if mode == "live" && !stoppedByUser {
                source = f.rawSamples ? "设备采集 · 原始 ADC（待标定）" : config.calibrated ? "设备采集 · 操作者确认标定" : "设备采集 · 参考系数未标定"
                if !f.rawSamples { powerSum += m.powerW; powerCount += 1 }
                if config.calibrated && m.powerW >= 0 { energy += m.powerW*m.durationS/3_600_000 }
            }
        } catch { log("波形未采用：\(error.localizedDescription)") }
    }

    func send(_ data: Data) { connection?.send(content:data,completion:.contentProcessed { [weak self] e in if let e = e { DispatchQueue.main.async { self?.log("发送失败：\(e.localizedDescription)") } } }) }
    var deviceCommandCanSend: Bool {
        mode == "live" && connected && config.transport == "client" && ["socket128","ys8000"].contains(config.protocolName)
            && !deviceCommandBusy && Date().timeIntervalSince(lastDeviceCommandAt) >= 1
    }
    func sendDeviceCommand(_ command: DeviceCommand, encoding: DeviceCommandEncoding) throws {
        guard mode == "live",connected,let conn = connection,config.transport == "client",
              ["socket128","ys8000"].contains(config.protocolName) else { throw MeterError.invalid("请先使用本次插座或 YS8000 模式连接设备；离线状态不能发送") }
        guard !deviceCommandBusy,Date().timeIntervalSince(lastDeviceCommandAt) >= 1 else { throw MeterError.invalid("上一条指令尚在发送，请稍后再点击") }
        let data = command.bytes(encoding:encoding), hex = deviceCommandHex(data), token = generation
        do { try recorder.event("device_command_requested",details:["command":command.rawValue,"encoding":encoding.rawValue,"hex":hex,"operator_initiated":true,"target_host":config.host,"target_port":config.port]) }
        catch { failStorage(error); throw error }
        deviceCommandBusy = true; lastDeviceCommandAt = Date()
        deviceCommandMessage = "正在发送：\(command.title) · HEX \(hex)"
        conn.send(content:data,completion:.contentProcessed { [weak self,weak conn] error in DispatchQueue.main.async {
            guard let self = self,let conn = conn,self.generation == token,self.connection === conn else { return }
            self.deviceCommandBusy = false
            if let error = error { self.deviceCommandMessage = "发送失败："+error.localizedDescription+"；未自动重试" }
            else {
                self.deviceCommandMessage = "已发送：\(command.title) · HEX \(hex)；设备执行结果未核实"
                if command == .stopData {
                    self.stoppedByUser = true; self.collecting = false; self.captureUntil = nil
                    self.powerCount = 0; self.powerSum = 0; self.rawWindowPoints = 0; self.rawSquaresV = 0; self.rawSquaresI = 0
                    self.referencePowerWindow.reset();self.referencePowerHistory = []
                    self.loadState = LoadState(); self.powerHistory = []
                    self.decoder.discardedBytes += self.decoder.buffer.count; self.decoder.buffer = []
                } else if command == .startData {
                    self.stoppedByUser = false; self.collecting = false; self.lastData = nil; self.connectionBegan = Date()
                    self.textQueryUntil = nil; self.loadState = LoadState()
                }
            }
            self.log(self.deviceCommandMessage); self.publish()
        } })
        publish()
    }
    func stopCollection() {
        if connected && config.protocolName == "ys8000" { send(Data("$".utf8)) }
        stoppedByUser = true; collecting = false; captureUntil = nil; powerSum = 0; powerCount = 0
        if config.protocolName != "ys8000" { disconnect(); log("已停止并断开连接（主动推送模式，未发送停止指令）") } else { log("已发送 $，停止本机采集") }
    }
    func disconnect() {
        if connected && config.protocolName == "ys8000" { send(Data("$".utf8)) }
        wantsConnection = false; reconnectAt = nil; retryDate = nil
        generation += 1; connection?.cancel(); connection = nil; listener?.cancel(); listener = nil
        discoveryListener?.cancel(); discoveryListener = nil; discoveryPeers.forEach { $0.cancel() }; discoveryPeers.removeAll()
        webhookTask?.cancel(); webhookTask = nil; webhookInFlight = false
        deviceCommandBusy = false; deviceCommandMessage = "未连接 · 输出供电状态未核实；断开连接不发送继电器指令"
        powerSum = 0; powerCount = 0
        referencePowerWindow.reset()
        connected = false; collecting = false; captureUntil = nil; textQueryUntil = nil; loadState = LoadState()
        do { try recorder.finish(reason:"manual_stop") } catch { storageError = error.localizedDescription; log("自动保存结束检查："+storageError) }
        syncDrive()
    }
    func resetData() {
        decoder = FrameDecoder(config)
        raw = Data(); bytesReceived = 0; lastData = nil; fileCaptureDate = nil; lastMetrics = nil; hardware = [:]; lastFrame = MeterFrame(); energy = 0
        rawWindowPoints = 0; rawSquaresV = 0; rawSquaresI = 0; rateStart = nil; ratePoints = 0; receivedRate = nil; lastStats = [:]
        summaries = []; savedSummaryCount = 0; powerHistory = []; powerCount = 0; powerSum = 0; loadState = LoadState(); lastSummary = Date(); stoppedByUser = false; sessionID = UUID().uuidString
        deviceCommandBusy = false; lastDeviceCommandAt = .distantPast; deviceCommandMessage = "尚未发送指令 · 输出供电状态未核实"
        lastReferencePower = nil;referencePowerWindow.reset();referencePowerRows = [];referencePowerHistory = [];referencePowerError = ""
    }
    func tick() {
        if let due = reconnectAt, Date() >= due, wantsConnection, connection == nil { reconnectAt = nil; connectClient(token:generation) }
        if connected, config.transport == "client", wantsConnection, !stoppedByUser {
            let last = lastData.map { max($0,connectionBegan) } ?? connectionBegan
            if Date().timeIntervalSince(last) > 15, let conn = connection { connectionLost(conn,reason:"15 秒没有有效帧，重新建立连接",token:generation) }
        }
        if Date() >= nextMirror { nextMirror = Date().addingTimeInterval(15); syncDrive() }
        if mode == "demo" { demoWave() }
        if let until = captureUntil, Date() >= until { captureUntil = nil; if config.protocolName == "ys8000" { stopCollection() }; log("短时抓包结束：保留 \(raw.count) 字节，可导出原始 BIN") }
        if Date().timeIntervalSince(lastSummary) >= 1 {
            do { try recorder.checkpoint() } catch { failStorage(error) }
            if mode == "live", !stoppedByUser, rawWindowPoints > 0 {
                let time = ISO8601DateFormatter().string(from:Date())
                var row: [String:Any] = ["timestamp":time,"session_id":sessionID,"device_id":decoder.deviceID.isEmpty ? "meter-01" : decoder.deviceID,
                    "source":config.host.hasPrefix("127.") ? "loopback_test_NOT_hardware" : "device_raw_adc",
                    "voltage_adc_rms":sqrt(rawSquaresV/Double(rawWindowPoints)),"current_adc_rms":sqrt(rawSquaresI/Double(rawWindowPoints)),
                    "received_points":rawWindowPoints,"power_w":NSNull(),"energy_kwh":NSNull(),"calibrated":false,"load_state":"待标定",
                    "sample_rate_configured":config.sampleRate,"valid_frames":decoder.goodFrames,"discarded_bytes":decoder.discardedBytes,"invalid_frames":decoder.badFrames]
                if let watts = referencePowerWindow.average {
                    row["estimated_power_w"] = watts;row["power_quality"] = "reference_estimate_NOT_calibrated"
                    row["voltage_scale"] = config.voltageScale;row["current_scale"] = config.currentScale
                    row["voltage_offset_adc"] = config.voltageOffset;row["current_offset_adc"] = config.currentOffset;row["current_sign"] = config.currentSign
                    referencePowerRows.append(row);if referencePowerRows.count > 86400 { referencePowerRows.removeFirst(referencePowerRows.count-86400) }
                    referencePowerHistory.append(["power":watts,"time":time]);if referencePowerHistory.count > 180 { referencePowerHistory.removeFirst() }
                }
                referencePowerWindow.reset()
                do { try recorder.summary(row) } catch { failStorage(error) }
                pushWebhook(row)
                rawWindowPoints = 0; rawSquaresV = 0; rawSquaresI = 0
            }
            if mode == "live", powerCount > 0, let m = lastMetrics {
                let p = powerSum/Double(powerCount), time = ISO8601DateFormatter().string(from:Date())
                let state = loadState.update(power:p,now:Date(),config:config)
                var row: [String:Any] = ["timestamp":time,"device_id":decoder.deviceID.isEmpty ? "meter-01" : decoder.deviceID,"power_w":p,"voltage_rms":m.voltageRMS,"current_rms":m.currentRMS,"source":"mac_\(config.protocolName)","session_id":sessionID,"sample_rate_hz":config.sampleRate,"calibrated":config.calibrated,"load_state":state,"energy_basis":"captured_waveform_integral"]
                row["energy_kwh"] = config.calibrated ? energy : NSNull()
                do { try recorder.summary(row) } catch { failStorage(error) }
                summaries.append(row); if storageError.isEmpty { savedSummaryCount = summaries.count }
                if summaries.count > 86400 { summaries.removeFirst(summaries.count-86400) }
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
        if !storageError.isEmpty { return "保存异常 · 采集已暂停" }
        if let at = reconnectAt, wantsConnection { return "等待重连 · \(max(0,Int(ceil(at.timeIntervalSinceNow)))) 秒" }
        return listener != nil ? "监听中 · 等待设备" : connection != nil ? "正在连接插座…" : "未连接"
    }
    func rawMetricsObject() -> [String:Any] {
        guard let m = lastMetrics else { return [:] }
        return ["voltageRMS":m.voltageRMS,"currentRMS":m.currentRMS,"count":m.count,"durationS":m.durationS,"warnings":m.warnings,"units":"ADC counts"]
    }
    func publish() {
        lastPublish = Date()
        var packet: [String:Any] = ["event":"state","mode":mode,"status":status(),"source":source,"connected":connected,"listening":listener != nil,"collecting":collecting,"bytes":bytesReceived,"goodFrames":decoder.goodFrames,"badFrames":decoder.badFrames,"discarded":decoder.discardedBytes,"deviceID":decoder.deviceID,"logs":logLines,"rawBytes":raw.count,"rows":summaries.count,"history":powerHistory,"hardware":hardware,"calibrated":config.calibrated,"loadState":mode == "live" && connected && collecting && lastData.map({Date().timeIntervalSince($0)<=5}) == true ? loadState.state : "未知 / 非实时","energy":config.calibrated && mode == "live" ? energy : NSNull(),"integrity":lastFrame.integrity]
        packet["timestamp"] = (fileCaptureDate ?? lastData).map { ISO8601DateFormatter().string(from:$0) } ?? ""
        packet["timestampLabel"] = fileCaptureDate != nil ? "原始采集结束" : mode == "file" ? "文件分析时间" : "最后有效帧"
        packet["rawSamples"] = lastFrame.rawSamples
        packet["connecting"] = connection != nil && !connected || reconnectAt != nil
        packet["storagePath"] = recorder.root.path
        packet["savedBytes"] = recorder.savedBytes
        packet["storageError"] = storageError
        packet["driveStatus"] = mirrorMessage
        packet["drivePending"] = mirrorPending
        packet["driveCopied"] = mirrorCopied
        packet["receiveRate"] = receivedRate ?? NSNull()
        packet["rawStats"] = lastStats
        packet["protocol"] = config.protocolName
        packet["deviceCommandCanSend"] = deviceCommandCanSend
        packet["deviceCommandBusy"] = deviceCommandBusy
        packet["deviceCommandMessage"] = deviceCommandMessage
        packet["referencePower"] = lastReferencePower.map{object($0)} ?? NSNull()
        packet["referencePowerError"] = referencePowerError
        packet["referencePowerRows"] = referencePowerRows.count
        packet["referencePowerHistory"] = referencePowerHistory
        packet["canFitReferencePower"] = mode == "live" && connected && !stoppedByUser && lastFrame.rawSamples && lastData.map{Date().timeIntervalSince($0) < 3} == true
        if lastFrame.rawSamples { packet["rawMetrics"] = rawMetricsObject(); if mode == "live" && connected && lastData.map({Date().timeIntervalSince($0)<=5}) == true { packet["loadState"] = "待标定" } }
        else if let m = lastMetrics { packet["metrics"] = object(m) }
        packet["voltage"] = Array(lastFrame.voltage.prefix(640)); packet["current"] = Array(lastFrame.current.prefix(640))
        emit(packet)
    }
    func log(_ s: String) {
        if recorder.active && storageError.isEmpty { do { try recorder.event("log",details:["message":s]) } catch { storageError = error.localizedDescription } }
        let time = DateFormatter(); time.dateFormat = "HH:mm:ss"; logLines.append("[\(time.string(from:Date()))] \(s)"); if logLines.count > 120 { logLines.removeFirst() } }
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
        try loadBinary(url)
    }
    func loadBinary(_ url: URL, capture: Bool = false) throws {
        let size = (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size <= 16_777_216 else { throw MeterError.invalid("BIN 文件最大 16 MiB") }
        let data = try Data(contentsOf:url)
        let candidateConfig = capture ? MeterConfig() : config
        let d = FrameDecoder(candidateConfig,expectRegistration:candidateConfig.transport == "server" && candidateConfig.registration && candidateConfig.protocolName == "isocket")
        var last: MeterFrame?
        for s in stride(from:0,to:data.count,by:4096) { if let f = d.feed(Data(data[s..<min(s+4096,data.count)])).last { last = f } }
        guard let last = last else { throw MeterError.invalid("未解析出有效帧：核对协议、注册头和帧配置。原始文件未修改") }
        guard confirmDiscard() else { return }
        config = candidateConfig; emit(["event":"config","config":object(config)])
        disconnect(); resetData(); mode = "file"; source = "BIN 离线回放 · \(url.lastPathComponent)"; decoder = d; raw = Data(data.suffix(2_097_152)); bytesReceived = data.count
        consume(last)
        if capture { source = "本次实测文件回放 · F251D351（非实时）"; fileCaptureDate = ISO8601DateFormatter().date(from:"2026-10-19T14:53:25Z") }
        log("离线回放 \(d.goodFrames) 帧，校验失败 \(d.badFrames) 次，跳过 \(d.discardedBytes) 字节；显示最后一帧。不写入真实摘要。")
    }
    func saveWave() throws {
        guard !lastFrame.voltage.isEmpty else { throw MeterError.invalid("没有可导出的波形") }
        var text = lastFrame.rawSamples ? "current_adc,voltage_adc,label\r\n" : "I,V,label\r\n"
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
    func savePowerReadings() throws {
        guard !referencePowerRows.isEmpty else { throw MeterError.invalid("暂无实时参考瓦数记录；历史回放不伪造成实时数据") }
        let keys = ["timestamp","estimated_power_w","power_quality","calibrated","power_w","energy_kwh","source","session_id","voltage_scale","current_scale","voltage_offset_adc","current_offset_adc","current_sign"]
        var text = "\u{feff}"+keys.joined(separator:",")+"\r\n"
        for row in referencePowerRows { text += keys.map { key in let v = row[key]; let s = v == nil || v is NSNull ? "" : String(describing:v!); return "\""+s.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }.joined(separator:",")+"\r\n" }
        try write(Data(text.utf8),name:"参考瓦数-未标定.csv",ext:"csv")
    }
    func applyReferencePower(_ body: [String:Any]) throws {
        guard mode == "live",connected,!stoppedByUser,lastFrame.rawSamples,
              lastData.map({Date().timeIntervalSince($0)<3}) == true else { throw MeterError.invalid("请先连接插座并接收新的原始波形，再对照参考仪表调整") }
        guard let power = body["measuredPower"] as? Double else { throw MeterError.invalid("缺少参考仪表实测瓦数") }
        let measuredVoltage = body["measuredVoltage"] as? Double
        let revised = try fitReferencePower(lastFrame.voltage,lastFrame.current,config:config,measuredPower:power,measuredVoltage:measuredVoltage)
        var local = revised;local.webhook = "";local.webhookEnabled = false
        try FileManager.default.createDirectory(at:recorder.root,withIntermediateDirectories:true)
        try JSONEncoder().encode(local).write(to:recorder.root.appendingPathComponent("reference-power-settings.json"),options:.atomic)
        config = revised;decoder.config = revised
        lastReferencePower = try referencePower(lastFrame.voltage,lastFrame.current,config:config)
        referencePowerWindow.reset();referencePowerHistory = []
        log("参考瓦数系数已按实测 \(power) W 调整；仅单点拟合，仍未标记为正式标定，请换另一负载复核")
        emit(["event":"config","config":object(config)]);publish()
    }
    func saveRaw() throws { guard !raw.isEmpty else { throw MeterError.invalid("暂无原始报文") }; try write(raw,name:"\(mode)-原始抓包.bin",ext:"bin") }
    func saveDiagnostic() throws {
        // Do not include webhook URLs or unredacted configuration responses.
        var packet: [String:Any] = ["app":"Green Meter Mac","version":"1.4.0","source":source,"status":status(),"protocol":config.protocolName,"sample_rate_configured":config.sampleRate,"calibrated":config.calibrated,"raw_samples":lastFrame.rawSamples,"device_id":decoder.deviceID,"bytes_received":bytesReceived,"valid_frames":decoder.goodFrames,"invalid_frames":decoder.badFrames,"discarded_bytes":decoder.discardedBytes,"integrity":lastFrame.integrity,"metrics":lastFrame.rawSamples ? [:] : lastMetrics.map{object($0)} ?? [:],"raw_metrics":lastFrame.rawSamples ? rawMetricsObject() : [:],"hardware":hardware,"captured_points":lastFrame.voltage.count,"notes":"socket128 依据 F251D351 实测文件验证帧头、长度、累加校验和尾字节。实际采样率、通道物理换算与标定仍待核对。"]
        packet["reference_power"] = lastReferencePower.map{object($0)} ?? NSNull()
        packet["reference_power_error"] = referencePowerError
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
    var quitPending = false
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
        window.title = "绿电实验室 1.4 · 实时瓦数与供电控制"; window.minSize = NSSize(width:950,height:680); window.contentView = web
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if let url = Bundle.main.url(forResource:"index",withExtension:"html") { web.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent()) }
    }
    @objc func about() { let a = NSAlert(); a.messageText = "绿电实验室 Mac 电表监测 1.4.0"; a.informativeText = "已加入 192.168.1.2:8266 实测格式；F251D351 文件解析通过 242 帧。默认显示原始 ADC，物理换算与采样率待核对。原生 Apple Silicon / Intel，离线运行。"; a.runModal() }
    func applicationWillTerminate(_ notification: Notification) { controller.disconnect() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.confirmDiscard() else { return .terminateCancel }
        guard !quitPending else { return .terminateLater }; quitPending = true
        var replied = false
        let reply = { if !replied { replied = true; sender.reply(toApplicationShouldTerminate:true) } }
        controller.finishForQuit(reply)
        // A stalled File Provider must not trap the user in the app; local files remain.
        DispatchQueue.main.asyncAfter(deadline:.now()+8,execute:reply)
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
