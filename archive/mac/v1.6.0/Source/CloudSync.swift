import Foundation
import Security

let greenMeterWebsite = URL(string:"https://green-meter-lab-v2.ziben-mac.workers.dev")!

struct CloudSettings: Codable {
    var deviceID = "meter-01"
    var enabled = false
    func validate() throws {
        guard deviceID.range(of:"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$",options:.regularExpression) != nil,
              !deviceID.lowercased().hasPrefix("demo-") else { throw MeterError.invalid("设备编号限 1–64 位英文字母、数字、下划线或连字符，不能以 demo- 开头") }
    }
}

protocol CloudKeyStore {
    func read(device: String) throws -> String?
    func save(_ key: String, device: String) throws
}

/// Credentials never enter WKWebView state, JSON settings, diagnostics or archives.
final class CloudKeychain: CloudKeyStore {
    private func query(_ device: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,
         kSecAttrService as String:"local.greenmeter.monitor.website-sync",
         kSecAttrAccount as String:greenMeterWebsite.host!+"|"+device]
    }
    func read(device: String) throws -> String? {
        var q = query(device); q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,let data = result as? Data,let key = String(data:data,encoding:.utf8) else {
            throw MeterError.invalid("无法读取钥匙串中的采集密钥，请解锁 Mac 钥匙串后重试")
        }
        return key
    }
    func save(_ key: String, device: String) throws {
        let q = query(device), value = Data(key.utf8)
        let status = SecItemUpdate(q as CFDictionary,[kSecValueData as String:value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw MeterError.invalid("采集密钥未能保存到 Mac 钥匙串") }
        } else if status != errSecSuccess { throw MeterError.invalid("采集密钥未能更新到 Mac 钥匙串") }
    }
}

struct CloudReading: Codable {
    let device_id: String
    let timestamp: String
    let session_id: String
    let estimated_power_w: Double
    let energy_kwh: Double? = nil
    let quality = "reference"
    let state = "unknown"
    let state_source = "unknown"
    enum CodingKeys: String,CodingKey { case device_id,timestamp,session_id,estimated_power_w,energy_kwh,quality,state,state_source }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(device_id,forKey:.device_id);try c.encode(timestamp,forKey:.timestamp)
        try c.encode(session_id,forKey:.session_id);try c.encode(estimated_power_w,forKey:.estimated_power_w)
        try c.encodeNil(forKey:.energy_kwh);try c.encode(quality,forKey:.quality)
        try c.encode(state,forKey:.state);try c.encode(state_source,forKey:.state_source)
    }
}

struct CloudSignal: Codable {
    let time: String
    let values: [Double]
    let frames: Int
    let voltagePreviewADC: [Double]
    let currentPreviewADC: [Double]
}

struct CloudRecord: Codable {
    let device_id: String
    let profile: String
    let sample_rate_configured: Double
    let reading: CloudReading
    let window: CloudSignal
    static func make(config: MeterConfig, device: String, session: String, watts: Double,
                     window: LearningFeatureWindow) throws -> CloudRecord {
        try config.validate()
        try CloudSettings(deviceID:device).validate()
        guard config.protocolName == "socket128",config.transport == "client",
              !config.host.hasPrefix("127."),config.host != "0.0.0.0",
              watts.isFinite,watts >= 0,window.frames >= 4,window.values.count == 12,
              window.values.allSatisfy(\.isFinite) else { throw MeterError.invalid("此数据不符合真实插座同步要求") }
        _ = try applianceFeatures(window.voltagePreviewADC,window.currentPreviewADC)
        let date = ISO8601DateFormatter();date.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let time = date.string(from:window.time)
        return CloudRecord(device_id:device,profile:learningProfile(config),sample_rate_configured:config.sampleRate,
            reading:CloudReading(device_id:device,timestamp:time,session_id:session,estimated_power_w:watts),
            window:CloudSignal(time:time,values:window.values,frames:window.frames,
                voltagePreviewADC:window.voltagePreviewADC,currentPreviewADC:window.currentPreviewADC))
    }
}

private struct CloudBatch: Encodable {
    let device_id: String
    let profile: String
    let sample_rate_configured: Double
    let readings: [CloudReading]
    let windows: [CloudSignal]
}

private final class CloudNoRedirect: NSObject,URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,completionHandler: @escaping (URLRequest?)->Void) { completionHandler(nil) }
}

/// One serial queue owns persistence, settings, retries and acknowledgment handling.
/// Only acknowledged records are removed; native raw capture and Drive backup are independent.
final class CloudSync {
    private struct Pending { let url: URL;let device: String;let profile: String;let session: String;let bytes: Int }
    private let queue = DispatchQueue(label:"greenmeter.website-sync",qos:.utility)
    private let lock = NSLock()
    private var publicState: [String:Any] = ["enabled":false,"ready":false,"deviceID":"meter-01","message":"正在检查网站同步队列","pending":0,"keyConfigured":false]
    private let root: URL
    private let endpoint: URL
    private let keys: CloudKeyStore
    private let quota: Int
    private var settings = CloudSettings()
    private var pending: [Pending] = []
    private var pendingBytes = 0
    private var unreadable = 0
    private var configured = false
    private var initialized = false
    private var persistenceError = false
    private var blocked = false
    private var inFlight = false
    private var nextAttempt = Date.distantPast
    private var failures = 0
    private var revision = 0
    private var lastSuccess = ""
    private var message = "未开启网站同步"
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil;c.urlCredentialStorage = nil;c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 1;c.timeoutIntervalForRequest = 15;c.timeoutIntervalForResource = 20
        return URLSession(configuration:c,delegate:CloudNoRedirect(),delegateQueue:nil)
    }()

    init(root: URL,keys: CloudKeyStore = CloudKeychain(),quota: Int = 1_073_741_824,
         testEndpoint: URL? = nil) {
        self.root = root.appendingPathComponent("website-sync",isDirectory:true)
        self.keys = keys;self.quota = quota
        // Tests may bind only loopback; the shipping UI never accepts an arbitrary upload URL.
        if let u = testEndpoint {
            precondition(u.scheme == "http" && u.host == "127.0.0.1" && u.path == "/api/ingest")
            self.endpoint = u
        } else { self.endpoint = greenMeterWebsite.appendingPathComponent("api/ingest") }
        queue.async { self.restore() }
    }
    var snapshot: [String:Any] { lock.lock();defer{lock.unlock()};return publicState }
    private func publish() {
        let other = pending.filter{$0.device != settings.deviceID}.count
        let state: [String:Any] = ["enabled":settings.enabled,"ready":initialized && !persistenceError,
            "deviceID":settings.deviceID,"keyConfigured":configured,"message":message,
            "pending":pending.count,"pendingBytes":pendingBytes,"otherDevicePending":other,
            "unreadable":unreadable,"lastSuccess":lastSuccess,"uploading":inFlight,
            "website":greenMeterWebsite.absoluteString,"blocked":blocked]
        lock.lock();publicState = state;lock.unlock()
    }
    private func privateWrite(_ data: Data,to url: URL) throws {
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func restore() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let configURL = root.appendingPathComponent("settings.json")
            if fm.fileExists(atPath:configURL.path) { settings = try JSONDecoder().decode(CloudSettings.self,from:Data(contentsOf:configURL));try settings.validate() }
            let files = try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.pathExtension == "pending"}.sorted{$0.lastPathComponent < $1.lastPathComponent}
            for url in files {
                do {
                    let data = try Data(contentsOf:url),r = try JSONDecoder().decode(CloudRecord.self,from:data)
                    pending.append(Pending(url:url,device:r.device_id,profile:r.profile,session:r.reading.session_id,bytes:data.count));pendingBytes += data.count
                } catch { unreadable += 1 }
            }
            configured = try keys.read(device:settings.deviceID) != nil
            message = settings.enabled ? "等待同步；软件需保持运行，可最小化" : "未开启网站同步"
        } catch { persistenceError = true;message = "网站同步初始化失败；本地采集不受影响，请检查磁盘与钥匙串" }
        initialized = true;publish()
    }
    func configure(device: String,key: String,enabled: Bool,completion: @escaping (String?)->Void) {
        queue.async {
            do {
                guard self.initialized,!self.persistenceError else { throw MeterError.invalid("网站同步尚未就绪，请检查磁盘或重新打开软件") }
                let next = CloudSettings(deviceID:device,enabled:enabled);try next.validate()
                if !key.isEmpty {
                    guard key.range(of:"^gml_[a-f0-9]{64}$",options:.regularExpression) != nil else { throw MeterError.invalid("请输入网站生成的采集密钥（gml_ 开头），不要填管理员口令") }
                    try self.keys.save(key,device:device)
                }
                let available = try self.keys.read(device:device) != nil
                guard !enabled || available else { throw MeterError.invalid("请先填写网站的采集密钥") }
                try self.privateWrite(JSONEncoder().encode(next),to:self.root.appendingPathComponent("settings.json"))
                self.settings = next;self.configured = available;self.blocked = false;self.failures = 0
                self.revision += 1;self.nextAttempt = .distantPast
                self.message = enabled ? "已开启；等待真实采集或待补传记录" : "网站同步已暂停；待传数据保留"
                self.publish();DispatchQueue.main.async { completion(nil) };self.pump()
            } catch { let note = error.localizedDescription;DispatchQueue.main.async{completion(note)} }
        }
    }
    func enqueue(_ record: CloudRecord) {
        queue.async {
            guard self.initialized,self.settings.enabled,self.configured,!self.persistenceError,
                  record.device_id == self.settings.deviceID else { return }
            do {
                let data = try JSONEncoder().encode(record)
                guard self.pendingBytes+data.count <= self.quota else {
                    self.message = "网站待传队列已达 1 GB 上限；新数据仍保存在原始采集目录，请联网补传";self.publish();return
                }
                let name = String(format:"%016lld",Int64(Date().timeIntervalSince1970*1000))+"-"+UUID().uuidString+".pending"
                let url = self.root.appendingPathComponent(name)
                try self.privateWrite(data,to:url)
                self.pending.append(Pending(url:url,device:record.device_id,profile:record.profile,session:record.reading.session_id,bytes:data.count))
                self.pendingBytes += data.count;self.publish()
            } catch { self.persistenceError = true;self.message = "网站待传记录保存失败；本地原始采集仍独立保存";self.publish() }
        }
    }
    func tick() { queue.async { self.pump() } }
    func retryNow() { queue.async { self.blocked = false;self.nextAttempt = .distantPast;self.pump() } }
    private func pump() {
        guard initialized,settings.enabled,configured,!blocked,!inFlight,!persistenceError,Date() >= nextAttempt,
              let first = pending.first(where:{$0.device == settings.deviceID}) else { return }
        let selected = Array(pending.filter{$0.device == first.device && $0.profile == first.profile && $0.session == first.session}.prefix(10))
        do {
            guard let key = try keys.read(device:first.device) else { throw MeterError.invalid("缺少采集密钥") }
            let records = try selected.map{try JSONDecoder().decode(CloudRecord.self,from:Data(contentsOf:$0.url))}
            let batch = CloudBatch(device_id:first.device,profile:first.profile,sample_rate_configured:records[0].sample_rate_configured,
                readings:records.map(\.reading),windows:records.map(\.window))
            var request = URLRequest(url:endpoint);request.httpMethod = "POST"
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
            request.httpBody = try JSONEncoder().encode(batch)
            inFlight = true;message = "正在上传 \(selected.count) 条记录";publish()
            let sentRevision = revision
            session.dataTask(with:request){data,response,error in self.queue.async {
                self.inFlight = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let receipt = data.flatMap{try? JSONSerialization.jsonObject(with:$0)} as? [String:Any]
                let inserted = receipt?["inserted"] as? Int,duplicates = receipt?["duplicates"] as? Int
                let ack = error == nil && (200...299).contains(status) && inserted != nil && duplicates != nil && inserted! >= 0 && duplicates! >= 0 && inserted!+duplicates! == selected.count
                if ack {
                    do {
                        for item in selected {
                            try FileManager.default.removeItem(at:item.url)
                            self.pending.removeAll{$0.url == item.url};self.pendingBytes -= item.bytes
                        }
                        self.lastSuccess = ISO8601DateFormatter().string(from:Date())
                        self.failures = 0;self.message = self.settings.enabled ? "上传成功；等待下一批" : "已暂停；本次在途上传已确认"
                        self.nextAttempt = Date().addingTimeInterval(5)
                    } catch { self.persistenceError = true;self.message = "服务器已接收，但本地队列整理失败；保留文件可安全重试" }
                } else if sentRevision == self.revision {
                    self.failures += 1
                    if status == 401 || status == 403 { self.blocked = true;self.message = "采集密钥无效或权限不足；请重新保存网站采集密钥，待传记录保留" }
                    else if (300...499).contains(status) && status != 408 && status != 429 {
                        self.blocked = true;self.message = "网站拒收（HTTP \(status)）；请检查设备编号和协议，待传记录保留"
                    } else {
                        let delay = min(60.0,pow(2,Double(min(6,self.failures))))
                        self.nextAttempt = Date().addingTimeInterval(delay)
                        self.message = status >= 200 && status < 300 ? "网站回执不完整；记录保留，稍后重试" : "暂时无法连接网站；\(Int(delay)) 秒后重试，待传记录保留"
                    }
                }
                self.publish()
            }}.resume()
        } catch { blocked = true;message = "无法准备上传；请检查钥匙串和待传文件，原始采集保留";publish() }
    }
}
