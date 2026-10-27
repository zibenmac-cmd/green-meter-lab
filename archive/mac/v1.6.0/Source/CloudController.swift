import Foundation
import AppKit

extension MeterController {
    func resetCloudWindow() {
        cloudWindow = LearningWindow();cloudPower.reset();cloudSession = UUID().uuidString
        cloudLastFrame = nil;cloudLastTick = Date();cloudContext = ""
    }
    var canSyncCloudFrames: Bool {
        let state = cloud.snapshot
        return state["enabled"] as? Bool == true && state["ready"] as? Bool == true &&
            mode == "live" && connected && !stoppedByUser && storageError.isEmpty &&
            config.protocolName == "socket128" && config.transport == "client" &&
            !config.host.hasPrefix("127.") && config.host != "0.0.0.0"
    }
    func cloudFrame(_ frame: MeterFrame) {
        guard canSyncCloudFrames,frame.rawSamples,let watts = lastReferencePower,
              watts.powerW >= 0 else { resetCloudWindow();return }
        let state = cloud.snapshot,device = state["deviceID"] as? String ?? "meter-01"
        let context = device+"|"+learningProfile(config)+"|\(config.voltageScale)|\(config.currentScale)|\(config.voltageOffset)|\(config.currentOffset)|\(config.currentSign)"
        if cloudContext != context || cloudLastFrame.map({Date().timeIntervalSince($0)>1.5}) == true { resetCloudWindow();cloudContext = context }
        do {
            try cloudWindow.append(frame.voltage,frame.current)
            cloudPower.append(watts.powerW,points:watts.count);cloudLastFrame = Date()
        } catch { resetCloudWindow() }
    }
    func cloudTick() {
        cloud.tick()
        guard canSyncCloudFrames else { resetCloudWindow();return }
        let now = Date()
        guard now.timeIntervalSince(cloudLastTick) >= 1 else { return }
        defer { cloudLastTick = now;cloudPower.reset() }
        guard cloudLastFrame.map({now.timeIntervalSince($0)<1.5}) == true,
              let window = cloudWindow.take(now:now),let watts = cloudPower.average else { resetCloudWindow();return }
        do {
            let record = try CloudRecord.make(config:config,device:cloud.snapshot["deviceID"] as? String ?? "meter-01",session:cloudSession,watts:watts,window:window)
            cloud.enqueue(record)
        } catch { resetCloudWindow() }
    }
    func handleCloud(_ action: String,body: [String:Any]) {
        if action == "cloudRetry" { cloud.retryNow();return }
        if action == "cloudWebsite" { NSWorkspace.shared.open(greenMeterWebsite);return }
        resetCloudWindow()
        cloud.configure(device:body["device"] as? String ?? "meter-01",key:body["key"] as? String ?? "",enabled:body["enabled"] as? Bool == true) { [weak self] error in
            if let error = error { self?.emit(["event":"error","message":error]) }
            else { self?.emit(["event":"cloudSaved"]);self?.log("网站同步设置已保存；密钥仅存于 Mac 钥匙串") }
            self?.publish()
        }
    }
}
