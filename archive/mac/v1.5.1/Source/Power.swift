import Foundation

struct ReferencePower: Codable {
    let powerW: Double
    let voltageRMS: Double
    let currentRMS: Double
    let apparentVA: Double
    let powerFactor: Double?
    let count: Int
    var quality = "reference_estimate_NOT_calibrated"
}

/// Estimate from synchronous samples and explicit gains/offsets. Never assume 230 V,
/// remove a measured mean automatically, or substitute Vrms*Irms for active power.
func referencePower(_ voltageADC: [Double], _ currentADC: [Double], config: MeterConfig) throws -> ReferencePower {
    guard voltageADC.count == currentADC.count,(16...640000).contains(voltageADC.count),
          config.voltageScale.isFinite,config.currentScale.isFinite,config.voltageScale > 0,config.currentScale > 0,
          config.voltageOffset.isFinite,config.currentOffset.isFinite,[-1.0,1.0].contains(config.currentSign) else {
        throw MeterError.invalid("瓦数换算需要有效的同步双通道及换算系数")
    }
    var v2 = 0.0,i2 = 0.0,product = 0.0
    for (av,ai) in zip(voltageADC,currentADC) {
        let v = (av-config.voltageOffset)*config.voltageScale
        let i = (ai-config.currentOffset)*config.currentScale*config.currentSign
        guard av.isFinite,ai.isFinite,abs(av) <= 32768,abs(ai) <= 32768,
              v.isFinite,i.isFinite,abs(v) <= 2000,abs(i) <= 500 else { throw MeterError.invalid("参考瓦数换算超量程，请核对零点和系数") }
        v2 += v*v;i2 += i*i;product += v*i
    }
    let n = Double(voltageADC.count),vr = sqrt(v2/n),ir = sqrt(i2/n),p = product/n,s = vr*ir
    return ReferencePower(powerW:p,voltageRMS:vr,currentRMS:ir,apparentVA:s,powerFactor:s > 1e-9 ? max(-1,min(1,p/s)) : nil,count:voltageADC.count)
}

/// One reference point adjusts gains only. It does not certify zero, phase,
/// sample rate, other loads or thresholds and must not set calibrated=true.
func fitReferencePower(_ voltageADC: [Double], _ currentADC: [Double], config: MeterConfig,
                       measuredPower: Double, measuredVoltage: Double?) throws -> MeterConfig {
    guard measuredPower.isFinite,(1...50000).contains(measuredPower) else { throw MeterError.invalid("请输入参考仪表实测的有功功率（1–50000 W），不能填铭牌最大功率") }
    if let v = measuredVoltage { guard v.isFinite,(20...1000).contains(v) else { throw MeterError.invalid("参考电压应为 20–1000 V；不调整电压可留空") } }
    let before = try referencePower(voltageADC,currentADC,config:config)
    guard before.powerW >= 1,before.voltageRMS > 1,(before.powerFactor ?? 0) > 0.1 else {
        throw MeterError.invalid("当前信号过小、为负或相位异常，不能用噪声拟合瓦数；请先核对零点、极性并接入稳定参考负载")
    }
    let voltageRatio = measuredVoltage.map { $0/before.voltageRMS } ?? 1
    var result = config
    result.voltageScale *= voltageRatio
    result.currentScale *= measuredPower/before.powerW/voltageRatio
    result.calibrated = false
    try result.validate()
    _ = try referencePower(voltageADC,currentADC,config:result)
    return result
}

struct PowerWindow {
    private(set) var weightedSum = 0.0
    private(set) var points = 0
    mutating func append(_ power: Double, points n: Int) {
        guard power.isFinite,n > 0 else { return }
        weightedSum += power*Double(n);points += n
    }
    var average: Double? { points > 0 ? weightedSum/Double(points) : nil }
    mutating func reset() { weightedSum = 0;points = 0 }
}
