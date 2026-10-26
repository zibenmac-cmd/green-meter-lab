import Foundation
import CryptoKit

enum ApplianceState: String, Codable, CaseIterable {
    case off, standby, running
    var title: String { self == .off ? "关闭" : self == .standby ? "待机" : "运行" }
}
struct LearnedAppliance: Codable {
    let id: String
    let name: String
    let createdAt: Date
}
struct LearningLabel: Codable, Equatable {
    let applianceID: String
    let applianceName: String
    let state: ApplianceState
    // Low/zero consumption cannot identify the attached appliance.
    var key: String { state == .running ? applianceID+"|running" : "shared|"+state.rawValue }
    var title: String { state == .running ? applianceName+" · 运行" : state.title+"样本（不判断电器名称）" }
}
let learningFeatureVersion = "adc-shape-v1"
let learningFloors: [Double] = [0.15,0.15,0.08,0.15,0.08,0.08,0.03,0.03,0.03,0.03,0.03,0.10]

func learningProfile(_ config: MeterConfig) -> String {
    // Gains/offsets do not affect these raw-ADC classification features.
    "\(learningFeatureVersion)|\(config.protocolName)|\(config.transport)|\(config.host)|\(config.port)|\(config.sampleRate)|128"
}
func learningIsLoopback(_ config: MeterConfig) -> Bool { config.host.hasPrefix("127.") }

/// Centering here is only a classification feature. It never changes metered W.
/// Spectral bins are frame-shape features, not verified physical harmonics.
func applianceFeatures(_ v: [Double], _ i: [Double]) throws -> [Double] {
    guard v.count == 128,i.count == 128,v.allSatisfy({$0.isFinite && abs($0)<32760}),
          i.allSatisfy({$0.isFinite && abs($0)<32760}) else { throw MeterError.invalid("学习需要完整的 128 对原始 ADC，不能使用削顶或无效样本") }
    let n = Double(v.count),vm = v.reduce(0,+)/n,im = i.reduce(0,+)/n
    let a = v.map{$0-vm},b = i.map{$0-im}
    let vr = sqrt(a.reduce(0){$0+$1*$1}/n),ir = sqrt(b.reduce(0){$0+$1*$1}/n)
    let full = sqrt(i.reduce(0){$0+$1*$1}/n)
    guard vr > 5 else { throw MeterError.invalid("电压通道信号过小，不能保存学习样本") }
    let corr = ir > 1e-6 ? zip(a,b).reduce(0){$0+$1.0*$1.1}/n/vr/ir : 0
    let crest = ir > 1e-6 ? (b.map(abs).max() ?? 0)/ir : 0
    let dc = full > 1e-6 ? im/full : 0
    let rough = ir > 1e-6 ? (1..<b.count).reduce(0){$0+pow(b[$1]-b[$1-1],2)}/Double(b.count-1)/pow(ir,2) : 0
    var bands: [Double] = []
    for k in [1,2,3,4,8] {
        var real = 0.0,imag = 0.0
        for j in 0..<b.count { let angle = 2*Double.pi*Double(k*j)/n;real += b[j]*cos(angle);imag += b[j]*sin(angle) }
        bands.append(ir > 1e-6 ? min(1,2*(real*real+imag*imag)/(n*n*ir*ir)) : 0)
    }
    let result = [log1p(ir),log1p(full),dc,crest,max(-1,min(1,corr)),rough]+bands+[log1p(vr)]
    guard result.count == learningFloors.count,result.allSatisfy(\.isFinite) else { throw MeterError.invalid("学习特征无效") }
    return result
}

struct LearningFeatureWindow: Codable {
    let time: Date
    let values: [Double]
    let frames: Int
    let voltagePreviewADC: [Double]
    let currentPreviewADC: [Double]
}
struct LearningWindow {
    var sums = [Double](repeating:0,count:learningFloors.count)
    var frames = 0
    var previewV: [Double] = [],previewI: [Double] = []
    mutating func append(_ v: [Double], _ i: [Double]) throws {
        let values = try applianceFeatures(v,i)
        for j in values.indices { sums[j] += values[j] };frames += 1
        previewV = v;previewI = i
    }
    mutating func take(now: Date) -> LearningFeatureWindow? {
        defer { self = LearningWindow() }
        guard frames >= 4 else { return nil }
        return LearningFeatureWindow(time:now,values:sums.map{$0/Double(frames)},frames:frames,voltagePreviewADC:previewV,currentPreviewADC:previewI)
    }
}
struct LearningCapture: Codable {
    let id: String
    let label: LearningLabel
    let profile: String
    let source: String
    let featureVersion: String
    let startedAt: Date
    let endedAt: Date
    let acquisitionSession: String
    let rawByteStart: Int
    let rawByteEnd: Int
    let windows: [LearningFeatureWindow]
    func validate() throws {
        guard UUID(uuidString:id) != nil,UUID(uuidString:label.applianceID) != nil,
              !label.applianceName.isEmpty,label.applianceName.count <= 32,
              featureVersion == learningFeatureVersion,["device_user_label","loopback_test_NOT_hardware"].contains(source),
              (19...26).contains(endedAt.timeIntervalSince(startedAt)),(16...25).contains(windows.count),
              rawByteEnd > rawByteStart else { throw MeterError.invalid("学习段不完整或来源不受支持") }
        var previous = startedAt
        for w in windows {
            guard w.time > previous,w.time <= endedAt,w.time.timeIntervalSince(previous) <= 2.1,
                  w.frames >= 4,w.values.count == learningFloors.count,w.values.allSatisfy(\.isFinite),
                  w.voltagePreviewADC.count == 128,w.currentPreviewADC.count == 128 else { throw MeterError.invalid("学习段有缺失、重复或无效窗口") }
            previous = w.time
        }
        guard endedAt.timeIntervalSince(previous) <= 2.1 else { throw MeterError.invalid("学习段末尾缺失数据") }
    }
}
struct PendingLearningCapture {
    let label: LearningLabel
    let profile: String
    let source: String
    let startedAt: Date
    let acquisitionSession: String
    let rawByteStart: Int
    var windows: [LearningFeatureWindow] = []
}
struct LearningReview: Codable {
    let id: String
    let captureID: String
    let excluded: Bool
    let time: Date
}
struct ApplianceCentroid: Codable {
    let key: String
    let label: LearningLabel
    let center: [Double]
    let radius: Double
}
struct LearningMatch: Codable {
    let key: String?
    let appliance: String?
    let state: String
    let reason: String
    let distance: Double?
}
struct LearningValidationClass: Codable {
    let title: String
    let total: Int
    let correct: Int
    let rejected: Int
}
struct LearningValidation: Codable {
    let balancedAccuracy: Double
    let total: Int
    let correct: Int
    let rejected: Int
    let folds: Int
    let classes: [LearningValidationClass]
    let eligibleCaptureIDs: [String]
    let excludedIncompleteLabels: [String]
    let passed: Bool
    let method: String
}
struct ApplianceModel: Codable {
    let id: String
    let createdAt: Date
    let profile: String
    let source: String
    let fingerprint: String
    let featureVersion: String
    let mean: [Double]
    let scale: [Double]
    let classes: [ApplianceCentroid]
    var validation: LearningValidation?
    func predict(_ features: [Double]) -> LearningMatch {
        let unknown: (String)->LearningMatch = { LearningMatch(key:nil,appliance:nil,state:"未知",reason:$0,distance:nil) }
        guard features.count == learningFloors.count,features.allSatisfy(\.isFinite),
              mean.count == features.count,scale.count == features.count,
              scale.allSatisfy({$0.isFinite && $0>0}),classes.count >= 2 else { return unknown("模型或特征无效") }
        let x = features.indices.map{(features[$0]-mean[$0])/scale[$0]}
        let ranked = classes.map{c in (c,distance(x,c.center))}.sorted{$0.1<$1.1}
        guard let top = ranked.first,top.1 <= top.0.radius else { return unknown("与已学习样本差异较大") }
        if ranked.count > 1,ranked[1].1-top.1 < 0.18 || (ranked[1].1 > 0 && top.1/ranked[1].1 > 0.82) { return unknown("多个样本相近，暂不判断") }
        return LearningMatch(key:top.0.key,appliance:top.0.label.state == .running ? top.0.label.applianceName : nil,state:top.0.label.state.title,reason:"仅在已学习范围内匹配；不能证明供电继电器状态",distance:top.1)
    }
}
func distance(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count,!a.isEmpty else { return .infinity }
    return sqrt(zip(a,b).reduce(0){$0+pow($1.0-$1.1,2)}/Double(a.count))
}
func learningFingerprint(_ captures: [LearningCapture]) -> String {
    let text = captures.sorted{$0.id<$1.id}.map{$0.id+":"+$0.label.key}.joined(separator:"|")
    return SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()
}
func fitApplianceModel(_ captures: [LearningCapture], profile: String, source: String) throws -> ApplianceModel {
    guard !captures.isEmpty else { throw MeterError.invalid("没有学习样本") }
    let all = captures.flatMap{$0.windows.map(\.values)},d = learningFloors.count
    guard !all.isEmpty,all.allSatisfy({$0.count == d && $0.allSatisfy(\.isFinite)}) else { throw MeterError.invalid("模型特征不完整") }
    let mean = (0..<d).map{j in all.reduce(0){$0+$1[j]}/Double(all.count)}
    let scale = (0..<d).map{j in max(learningFloors[j],sqrt(all.reduce(0){$0+pow($1[j]-mean[j],2)}/Double(all.count)))}
    let grouped = Dictionary(grouping:captures,by:{$0.label.key})
    let classes = grouped.keys.sorted().map{key -> ApplianceCentroid in
        let group = grouped[key]!,vectors = group.flatMap{$0.windows.map(\.values)}.map{x in (0..<d).map{(x[$0]-mean[$0])/scale[$0]}}
        let center = (0..<d).map{j in vectors.reduce(0){$0+$1[j]}/Double(vectors.count)}
        let distances = vectors.map{distance($0,center)}.sorted()
        let q = distances[min(distances.count-1,Int(Double(distances.count-1)*0.95))]
        return ApplianceCentroid(key:key,label:group[0].label,center:center,radius:max(0.65,min(2.5,q*1.6+0.2)))
    }
    return ApplianceModel(id:UUID().uuidString,createdAt:Date(),profile:profile,source:source,fingerprint:learningFingerprint(captures),featureVersion:learningFeatureVersion,mean:mean,scale:scale,classes:classes,validation:nil)
}

/// Every held-out segment stays entirely out of its fold's scaler and centroids.
func trainAppliances(_ input: [LearningCapture], profile: String, source: String) throws -> ApplianceModel {
    let compatible = input.filter{$0.profile == profile && $0.source == source}
    guard Set(compatible.map(\.id)).count == compatible.count else { throw MeterError.invalid("重复的学习段编号") }
    for capture in compatible { try capture.validate() }
    let groups = Dictionary(grouping:compatible,by:{$0.label.key})
    let eligible = groups.filter{$0.value.count >= 3}
    guard eligible.count >= 2 else { throw MeterError.invalid("至少需要两类样本，每类采 3 段；可以先采一台电器的关闭与运行状态") }
    let keys = eligible.keys.sorted(),folds = min(5,eligible.values.map(\.count).min() ?? 3)
    let sorted = eligible.mapValues{$0.sorted{$0.startedAt<$1.startedAt}}
    var totals = [String:Int](),correct = [String:Int](),rejected = [String:Int]()
    for fold in 0..<folds {
        let test = keys.map{sorted[$0]![fold]},ids = Set(test.map(\.id))
        let training = keys.flatMap{sorted[$0]!}.filter{!ids.contains($0.id)}
        let model = try fitApplianceModel(training,profile:profile,source:source)
        for capture in test { for w in capture.windows {
            let match = model.predict(w.values),key = capture.label.key
            totals[key,default:0] += 1
            if match.key == key { correct[key,default:0] += 1 }
            if match.key == nil { rejected[key,default:0] += 1 }
        } }
    }
    let score = keys.reduce(0){$0+Double(correct[$1,default:0])/Double(max(1,totals[$1,default:0]))}/Double(keys.count)
    let used = keys.flatMap{sorted[$0]!}
    var model = try fitApplianceModel(used,profile:profile,source:source)
    model.validation = LearningValidation(balancedAccuracy:score,total:totals.values.reduce(0,+),correct:correct.values.reduce(0,+),rejected:rejected.values.reduce(0,+),folds:folds,classes:keys.map{LearningValidationClass(title:sorted[$0]![0].label.title,total:totals[$0,default:0],correct:correct[$0,default:0],rejected:rejected[$0,default:0])},eligibleCaptureIDs:used.map(\.id),excludedIncompleteLabels:groups.filter{$0.value.count < 3}.values.map{$0[0].label.title}.sorted(),passed:score >= 0.8,method:"按完整采集段留出交叉验证；未知计为错误。该结果不代表跨天、跨设备或未见电器准确率。")
    return model
}

final class ApplianceLearningStore {
    let root: URL
    private(set) var appliances: [LearnedAppliance] = []
    private(set) var captures: [LearningCapture] = []
    private(set) var reviews: [LearningReview] = []
    private(set) var models: [ApplianceModel] = []
    private(set) var warning = ""
    init(root: URL) { self.root = root; reload() }
    private func read<T: Decodable>(_ folder: URL, as: T.Type) -> [T] {
        guard let files = try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey]) else { return [] }
        var result: [T] = []
        for file in files.filter({$0.pathExtension == "json"}).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}).prefix(1000) {
            do {
                guard (try file.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max < 1_048_576 else { throw MeterError.invalid("学习文件超限") }
                let decoder = JSONDecoder();decoder.dateDecodingStrategy = .millisecondsSince1970
                result.append(try decoder.decode(T.self,from:Data(contentsOf:file)))
            } catch { warning = "部分学习文件无法读取，已保留原文件："+file.lastPathComponent }
        }
        return result
    }
    func reload() {
        warning = "";appliances = [];captures = [];reviews = [];models = []
        for bucket in ["真实采集","回环测试"] {
            let base = root.appendingPathComponent(bucket).appendingPathComponent("电器学习")
            appliances += read(base.appendingPathComponent("电器"),as:LearnedAppliance.self)
            captures += read(base.appendingPathComponent("样本"),as:LearningCapture.self)
            reviews += read(base.appendingPathComponent("复核"),as:LearningReview.self)
            models += read(base.appendingPathComponent("模型"),as:ApplianceModel.self)
        }
        appliances = appliances.sorted{$0.createdAt<$1.createdAt};captures = captures.sorted{$0.startedAt<$1.startedAt}
    }
    func excluded(_ id: String) -> Bool { reviews.filter{$0.captureID == id}.max(by:{$0.time<$1.time})?.excluded ?? false }
    func active(profile: String, source: String) -> [LearningCapture] { captures.filter{$0.profile == profile && $0.source == source && !excluded($0.id)} }
    private func save<T: Encodable>(_ value: T, folder: String, id: String, loopback: Bool) throws {
        guard UUID(uuidString:id) != nil else { throw MeterError.invalid("无效学习文件编号") }
        let target = root.appendingPathComponent(loopback ? "回环测试" : "真实采集").appendingPathComponent("电器学习").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let url = target.appendingPathComponent(id+".json")
        guard !FileManager.default.fileExists(atPath:url.path) else { throw MeterError.invalid("学习文件编号已存在") }
        let encoder = JSONEncoder();encoder.dateEncodingStrategy = .millisecondsSince1970;encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count < 1_048_576 else { throw MeterError.invalid("学习文件过大") }
        try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func add(name: String, loopback: Bool) throws -> LearnedAppliance {
        let cleaned = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !cleaned.isEmpty,cleaned.count <= 32,cleaned.rangeOfCharacter(from:.controlCharacters) == nil else { throw MeterError.invalid("电器名称须为 1–32 字，不含换行") }
        if let existing = appliances.first(where:{$0.name.caseInsensitiveCompare(cleaned) == .orderedSame}) { return existing }
        let entry = LearnedAppliance(id:UUID().uuidString,name:cleaned,createdAt:Date())
        try save(entry,folder:"电器",id:entry.id,loopback:loopback);appliances.append(entry);return entry
    }
    func saveCapture(_ capture: LearningCapture, loopback: Bool) throws {
        try capture.validate();guard captures.count < 900 else { throw MeterError.invalid("样本段已达 900 段，请先导出整理") }
        try save(capture,folder:"样本",id:capture.id,loopback:loopback);captures.append(capture)
    }
    func review(id: String, exclude: Bool, loopback: Bool) throws {
        guard captures.contains(where:{$0.id == id}) else { throw MeterError.invalid("样本不存在") }
        let previous = reviews.filter{$0.captureID == id}.map(\.time).max() ?? .distantPast
        let review = LearningReview(id:UUID().uuidString,captureID:id,excluded:exclude,time:max(Date(),previous.addingTimeInterval(0.001)))
        try save(review,folder:"复核",id:review.id,loopback:loopback);reviews.append(review)
    }
    func saveModel(_ model: ApplianceModel, loopback: Bool) throws {
        try save(model,folder:"模型",id:model.id,loopback:loopback);models.append(model)
    }
    func currentModel(profile: String, source: String) -> ApplianceModel? {
        let usable = active(profile:profile,source:source),groups = Dictionary(grouping:usable,by:{$0.label.key})
        let eligible = groups.values.filter{$0.count >= 3}.flatMap{$0}
        let fingerprint = learningFingerprint(eligible)
        return models.filter{$0.profile == profile && $0.source == source && $0.featureVersion == learningFeatureVersion && $0.validation?.passed == true && $0.fingerprint == fingerprint}.max(by:{$0.createdAt<$1.createdAt})
    }
}
