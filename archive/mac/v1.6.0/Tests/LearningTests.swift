import Foundation

func learningFixtureWave(amplitude: Double, third: Double = 0, phase: Double = 0) -> ([Double],[Double]) {
    let v = (0..<128).map{160*sin(2*Double.pi*Double($0)/128)+5}
    let i = (0..<128).map{j -> Double in let t = 2*Double.pi*Double(j)/128;return amplitude*(sin(t-phase)+third*sin(3*t))+18}
    return (v,i)
}
func learningFixtureCapture(appliance: LearnedAppliance, state: ApplianceState, index: Int, profile: String, amplitude: Double, third: Double = 0) throws -> LearningCapture {
    let began = Date(timeIntervalSince1970:1000+Double(index)*30)
    let wave = learningFixtureWave(amplitude:amplitude,third:third)
    let feature = try applianceFeatures(wave.0,wave.1)
    let windows = (1...20).map{LearningFeatureWindow(time:began.addingTimeInterval(Double($0)),values:feature,frames:50,voltagePreviewADC:wave.0,currentPreviewADC:wave.1)}
    return LearningCapture(id:UUID().uuidString,label:LearningLabel(applianceID:appliance.id,applianceName:appliance.name,state:state),profile:profile,source:"loopback_test_NOT_hardware",featureVersion:learningFeatureVersion,startedAt:began,endedAt:began.addingTimeInterval(20),acquisitionSession:"synthetic_test_"+UUID().uuidString,rawByteStart:0,rawByteEnd:518000,windows:windows)
}
func runLearningChecks() throws {
    let waveform = learningFixtureWave(amplitude:30,third:0.2),features = try applianceFeatures(waveform.0,waveform.1)
    check(features.count == 12 && features.allSatisfy(\.isFinite),"learning feature vector is finite")
    let sine = learningFixtureWave(amplitude:30),sineFeatures = try applianceFeatures(sine.0,sine.1)
    check(features[8] > sineFeatures[8]+0.01,"waveform shape distinguishes third-bin energy")
    do { _ = try applianceFeatures([1],[1]);check(false,"short frames rejected") } catch { checks += 1 }
    do { _ = try applianceFeatures(waveform.0,Array(repeating:.nan,count:128));check(false,"NaN features rejected") } catch { checks += 1 }
    do { _ = try applianceFeatures(waveform.0,Array(repeating:32767,count:128));check(false,"clipped ADC rejected") } catch { checks += 1 }
    do { _ = try applianceFeatures(Array(repeating:0,count:128),waveform.1);check(false,"missing voltage rejected") } catch { checks += 1 }
    var window = LearningWindow()
    try window.append(waveform.0,waveform.1)
    check(window.take(now:Date()) == nil,"insufficient new frames not reused")
    for _ in 0..<4 { try window.append(waveform.0,waveform.1) }
    let result = window.take(now:Date())
    check(result?.frames == 4 && window.frames == 0,"feature window consumes only fresh frames")
    check(window.take(now:Date()) == nil,"empty window is not backfilled")
    let root = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("green-learning-checks-"+UUID().uuidString)
    let store = ApplianceLearningStore(root:root)
    let lamp = try store.add(name:"台灯",loopback:true),fan = try store.add(name:"风扇",loopback:true)
    let duplicate = try store.add(name:" 台灯 ",loopback:true)
    check(duplicate.id == lamp.id,"catalog duplicate names reuse identity")
    do { _ = try store.add(name:"\n",loopback:true);check(false,"empty name rejected") } catch { checks += 1 }
    var config = MeterConfig();config.host = "127.0.0.1"
    let profile = learningProfile(config)
    var gains = config;gains.voltageScale *= 2
    check(learningProfile(gains) == profile,"reference gains do not silently change raw learning features")
    gains.host = "192.168.1.2"
    check(learningProfile(gains) != profile,"device and loopback profiles are isolated")
    var captures: [LearningCapture] = []
    for j in 0..<3 {
        captures.append(try learningFixtureCapture(appliance:lamp,state:.off,index:j,profile:profile,amplitude:0))
        captures.append(try learningFixtureCapture(appliance:lamp,state:.running,index:10+j,profile:profile,amplitude:30+Double(j)*0.2))
        captures.append(try learningFixtureCapture(appliance:fan,state:.running,index:20+j,profile:profile,amplitude:90+Double(j)*0.5,third:0.5))
    }
    for capture in captures { try capture.validate();try store.saveCapture(capture,loopback:true) }
    do { _ = try trainAppliances([captures[0]],profile:profile,source:"loopback_test_NOT_hardware");check(false,"insufficient independent segments cannot train") } catch { checks += 1 }
    let model = try trainAppliances(captures,profile:profile,source:"loopback_test_NOT_hardware")
    check(model.validation?.passed == true && model.validation?.balancedAccuracy == 1,"held-out synthetic segment validation")
    check(model.validation?.folds == 3 && model.validation?.total == 180,"all segment windows assigned to held-out folds")
    let lampWave = learningFixtureWave(amplitude:30.1),fanWave = learningFixtureWave(amplitude:90.2,third:0.5),offWave = learningFixtureWave(amplitude:0)
    let lampFeatures = try applianceFeatures(lampWave.0,lampWave.1)
    check(model.predict(lampFeatures).appliance == "台灯","known lamp classification")
    let fanFeatures = try applianceFeatures(fanWave.0,fanWave.1)
    check(model.predict(fanFeatures).appliance == "风扇","known fan classification")
    let off = model.predict(try applianceFeatures(offWave.0,offWave.1))
    check(off.state == "关闭" && off.appliance == nil,"no appliance name guessed for off baseline")
    let unseen = learningFixtureWave(amplitude:2000,third:0.9,phase:1.3)
    let unseenFeatures = try applianceFeatures(unseen.0,unseen.1)
    check(model.predict(unseenFeatures).key == nil,"unseen waveform rejected")
    check(model.predict([.nan]).key == nil,"malformed inference returns unknown")
    let wrongSource = try? trainAppliances(captures,profile:learningProfile(gains),source:"device_user_label")
    check(wrongSource == nil,"synthetic data cannot train a real-device model")
    try store.saveModel(model,loopback:true)
    check(store.currentModel(profile:profile,source:"loopback_test_NOT_hardware") != nil,"validated model selected")
    let restored = ApplianceLearningStore(root:root)
    check(restored.captures.count == 9 && restored.appliances.count == 2,"restart restores library")
    check(restored.currentModel(profile:profile,source:"loopback_test_NOT_hardware")?.id == model.id,"restart restores current model")
    try restored.review(id:captures[0].id,exclude:true,loopback:true)
    check(restored.currentModel(profile:profile,source:"loopback_test_NOT_hardware") == nil,"excluded training segment invalidates model")
    try restored.review(id:captures[0].id,exclude:false,loopback:true)
    let rerestore = ApplianceLearningStore(root:root)
    check(!rerestore.excluded(captures[0].id) && rerestore.currentModel(profile:profile,source:"loopback_test_NOT_hardware") != nil,"review restore remains ordered after restart")
    var conflicting: [LearningCapture] = []
    for j in 0..<3 {
        conflicting.append(try learningFixtureCapture(appliance:lamp,state:.running,index:j,profile:profile,amplitude:30))
        conflicting.append(try learningFixtureCapture(appliance:fan,state:.running,index:10+j,profile:profile,amplitude:30))
    }
    let ambiguous = try trainAppliances(conflicting,profile:profile,source:"loopback_test_NOT_hardware")
    check(ambiguous.validation?.passed == false && ambiguous.predict(sineFeatures).key == nil,"indistinguishable labels do not enable a model")
    let mirror = DriveMirror(source:root),target = root.deletingLastPathComponent().appendingPathComponent("learning-test-mirror-"+UUID().uuidString)
    let mirrored = try mirror.sync(to:target)
    check(mirrored.copied >= 14,"immutable library and models enter existing backup path")
    let secondMirror = try mirror.sync(to:target)
    check(secondMirror.copied == 0,"learning backup is idempotent")
    print("PASS: appliance-learning features, grouped validation, unknown rejection, persistence and mock backup. Synthetic only.")
}
