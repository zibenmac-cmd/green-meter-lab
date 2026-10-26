import Foundation

extension MeterController {
    var learningSource: String { learningIsLoopback(config) ? "loopback_test_NOT_hardware" : "device_user_label" }
    var learningReadiness: (code: String, message: String) {
        if !storageError.isEmpty { return ("storage", "本地保存失败，采集已暂停："+storageError) }
        if config.protocolName != "socket128" || config.transport != "client" {
            return ("profile", "请在左侧选择“本次插座 · 实测格式”，使用电脑主动连接设备。")
        }
        if mode == "file" || mode == "demo" { return ("offline", "当前是历史回放或离线演示；请连接插座，收到实时波形后再采集学习样本。") }
        if !connected {
            if connection != nil || reconnectAt != nil {
                return ("connecting", "正在连接 \(config.host):\(config.port)。"+(lastConnectionIssue.isEmpty ? "等待连接结果。" : "上次连接失败："+lastConnectionIssue))
            }
            return ("disconnected", "尚未连接插座。请先手动连接插座 Wi-Fi，再点击下方“连接插座”。")
        }
        if stoppedByUser { return ("paused", "数据发送已停止。请在“供电与数据按钮”中手动点击“开始发送数据 #”。") }
        guard let last = lastData, lastFrame.rawSamples else {
            return ("waiting", bytesReceived > 0 ? "已收到 \(bytesReceived) 字节，但尚无有效波形。请核对左侧实测协议与通信日志。" : "TCP 已连接，尚未收到波形；若设备未发送数据，请手动点击“开始发送数据 #”。")
        }
        if Date().timeIntervalSince(last) >= 1.5 { return ("stale", "实时波形已中断；请检查插座连接与数据发送，恢复后再采集。") }
        if mode != "live" || !collecting { return ("waiting", "等待本次连接的新实时波形；收到后即可采集。") }
        return ("ready", "已收到实时波形。选择电器当前的实际状态，点击“采集这一状态”并保持约 20 秒。")
    }
    var canCaptureLearning: Bool { learningReadiness.code == "ready" }
    func refreshLearningModel() {
        learningCachedModel = learner.currentModel(profile:learningProfile(config),source:learningSource)
        learningCachedProfile = learningProfile(config);learningMatch = nil;learningCandidate = "";learningStreak = 0
    }
    func interruptLearning(_ reason: String) {
        if learningCapture != nil { learningStatus = reason+"；本段未保存，请重新采集";log(learningStatus) }
        learningCapture = nil;learningWindow = LearningWindow();learningMatch = nil;learningStreak = 0;learningCandidate = ""
    }
    func learningFrame(_ frame: MeterFrame) {
        guard mode == "live",connected,!stoppedByUser,frame.rawSamples,config.protocolName == "socket128" else { return }
        do { try learningWindow.append(frame.voltage,frame.current) }
        catch { interruptLearning(error.localizedDescription);learningSignalError = error.localizedDescription }
    }
    func beginLearning(_ body: [String:Any]) throws {
        guard canCaptureLearning else { throw MeterError.invalid(learningReadiness.message) }
        guard learningCapture == nil else { throw MeterError.invalid("正在采集一段样本，请等待或取消") }
        guard let id = body["applianceID"] as? String,let appliance = learner.appliances.first(where:{$0.id == id}),
              let state = ApplianceState(rawValue:body["state"] as? String ?? "") else { throw MeterError.invalid("请先新增电器，再选择当前实际状态") }
        let now = Date()
        learningCapture = PendingLearningCapture(label:LearningLabel(applianceID:id,applianceName:appliance.name,state:state),profile:learningProfile(config),source:learningSource,startedAt:now,acquisitionSession:sessionID,rawByteStart:recorder.savedBytes)
        learningWindow = LearningWindow();learningLastTick = now;learningSignalError = ""
        learningStatus = "正在记录 \(appliance.name) · \(state.title)，请保持此状态约 20 秒"
        try recorder.event("learning_capture_started",details:["appliance":appliance.name,"state":state.rawValue,"label_source":"human_entered"])
        log(learningStatus)
    }
    func learningTick(now: Date = Date()) {
        if learningCachedProfile != learningProfile(config) { interruptLearning("连接配置已改变");refreshLearningModel() }
        guard canCaptureLearning else {
            if learningCapture != nil { interruptLearning("设备断连、暂停或数据中断") }
            learningWindow = LearningWindow();learningMatch = nil;learningStreak = 0;learningCandidate = "";return
        }
        // The 0.5 s run-loop timer can fire just below 1.000 s; allow scheduling jitter.
        guard now.timeIntervalSince(learningLastTick) >= 0.95 else { return }
        learningLastTick = now
        let window = learningWindow.take(now:now)
        if var capture = learningCapture {
            if let window = window {
                let last = capture.windows.last?.time ?? capture.startedAt
                guard window.time.timeIntervalSince(last) <= 2.1 else { interruptLearning("学习段中间缺少数据");return }
                capture.windows.append(window);learningCapture = capture
            } else if now.timeIntervalSince(capture.windows.last?.time ?? capture.startedAt) > 2.1 {
                interruptLearning("完整波形不足，未补造缺失样本");return
            }
            if now.timeIntervalSince(capture.startedAt) >= 20 {
                let finished = LearningCapture(id:UUID().uuidString,label:capture.label,profile:capture.profile,source:capture.source,featureVersion:learningFeatureVersion,startedAt:capture.startedAt,endedAt:now,acquisitionSession:capture.acquisitionSession,rawByteStart:capture.rawByteStart,rawByteEnd:recorder.savedBytes,windows:capture.windows)
                do {
                    try learner.saveCapture(finished,loopback:learningIsLoopback(config))
                    learningCapture = nil;learningStatus = "已保存一段：\(capture.label.applianceName) · \(capture.label.state.title)；继续采集或开始学习"
                    try recorder.event("learning_capture_saved",details:["capture_id":finished.id,"windows":finished.windows.count,"label_source":"human_entered"])
                    refreshLearningModel();syncDrive();log(learningStatus)
                } catch { interruptLearning(error.localizedDescription) }
            }
            return
        }
        guard let model = learningCachedModel,let window = window else { learningMatch = nil;learningStreak = 0;learningCandidate = "";return }
        let result = model.predict(window.values)
        guard let key = result.key else { learningMatch = result;learningStreak = 0;learningCandidate = "";return }
        if key == learningCandidate { learningStreak += 1 } else { learningCandidate = key;learningStreak = 1;learningMatch = nil }
        if learningStreak >= 3 { learningMatch = result }
    }
    func handleLearning(_ action: String, body: [String:Any]) throws {
        switch action {
        case "learningAdd":
            guard learningCapture == nil else { throw MeterError.invalid("请先完成本段采集") }
            let appliance = try learner.add(name:body["name"] as? String ?? "",loopback:learningIsLoopback(config))
            learningStatus = "已新增 \(appliance.name)。接上插座并连接后，选择实际状态开始采集"
            emit(["event":"learningAdded","id":appliance.id]);syncDrive()
        case "learningStart": try beginLearning(body)
        case "learningCancel": interruptLearning("已取消采集")
        case "learningTrain":
            guard learningCapture == nil else { throw MeterError.invalid("请先完成本段采集") }
            let active = learner.active(profile:learningProfile(config),source:learningSource)
            guard Set(active.map{$0.label.key}).count <= 20 else { throw MeterError.invalid("第一版最多学习 20 类，请先停用多余样本") }
            let model = try trainAppliances(active,profile:learningProfile(config),source:learningSource)
            try learner.saveModel(model,loopback:learningIsLoopback(config));learningLastValidation = model.validation
            refreshLearningModel();syncDrive()
            learningStatus = model.validation?.passed == true ? "学习完成，采集段留出验证已通过；实时识别仅覆盖已学范围" : "本次验证未通过，模型没有启用；请核对标签、补采不同时间的样本"
            log(learningStatus)
        case "learningReview":
            guard learningCapture == nil,let id = body["id"] as? String,let excluded = body["excluded"] as? Bool,
                  learner.captures.contains(where:{$0.id == id && $0.profile == learningProfile(config) && $0.source == learningSource}) else { throw MeterError.invalid("样本不属于当前设备，或正在采集中") }
            try learner.review(id:id,exclude:excluded,loopback:learningIsLoopback(config));refreshLearningModel();syncDrive()
            learningStatus = excluded ? "已停用该段，可随时恢复；需要时请重新学习" : "已恢复该段；请重新学习"
        case "learningExport":
            let captures = learner.captures.filter{$0.profile == learningProfile(config) && $0.source == learningSource}
            let data: [String:Any] = ["feature_version":learningFeatureVersion,"source":learningSource,"profile":learningProfile(config),"captures":learningObject(captures),"reviews":learningObject(learner.reviews.filter{r in captures.contains{$0.id == r.captureID}}),"model":learningCachedModel.map{learningObject($0)} ?? NSNull(),"notes":"人工标签；参考识别，不证明继电器状态或计量精度"]
            try write(JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]),name:"电器学习样本与模型.json",ext:"json")
        default: break
        }
    }
    func learningObject<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        return (try? JSONSerialization.jsonObject(with:encoder.encode(value))) ?? NSNull()
    }
    func learningPacket() -> [String:Any] {
        let active = learner.active(profile:learningProfile(config),source:learningSource)
        let grouped = Dictionary(grouping:active,by:{$0.label.key})
        let progress = grouped.keys.sorted().map{key -> [String:Any] in ["title":grouped[key]![0].label.title,"segments":grouped[key]!.count] }
        let current = learner.captures.filter{$0.profile == learningProfile(config) && $0.source == learningSource}
        let segments = current.suffix(8).reversed().map{c -> [String:Any] in ["id":c.id,"name":c.label.applianceName,"state":c.label.state.title,"time":ISO8601DateFormatter().string(from:c.endedAt),"windows":c.windows.count,"excluded":learner.excluded(c.id)] }
        let elapsed = learningCapture.map{Date().timeIntervalSince($0.startedAt)} ?? 0
        let validation = learningLastValidation ?? learningCachedModel?.validation
        let readiness = learningReadiness
        return ["appliances":learningObject(learner.appliances),"capturing":learningCapture != nil,"elapsed":elapsed,"windows":learningCapture?.windows.count ?? 0,"status":learningStatus,"warning":learner.warning.isEmpty ? learningSignalError : learner.warning,"readinessCode":readiness.code,"readinessMessage":readiness.message,"canCapture":canCaptureLearning && learningCapture == nil,"canTrain":learningCapture == nil && grouped.values.filter{$0.count >= 3}.count >= 2,"activeSegments":active.count,"segments":segments,"progress":progress,"modelReady":learningCachedModel != nil,"live":canCaptureLearning,"testMode":learningIsLoopback(config),"match":learningMatch.map{learningObject($0)} ?? NSNull(),"streak":learningStreak,"validation":validation.map{learningObject($0)} ?? NSNull()]
    }
}
