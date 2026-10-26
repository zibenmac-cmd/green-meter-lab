import Foundation

func runPowerChecks() throws {
    var cfg = MeterConfig();cfg.voltageScale = 2;cfg.currentScale = 0.01;cfg.voltageOffset = 5;cfg.currentOffset = 18
    let v = (0..<640).map { 230*sqrt(2)*sin(2*Double.pi*Double($0)/128)/cfg.voltageScale+cfg.voltageOffset }
    let i = (0..<640).map { 2*sqrt(2)*sin(2*Double.pi*Double($0)/128-Double.pi/3)/cfg.currentScale+cfg.currentOffset }
    let p = try referencePower(v,i,config:cfg)
    close(p.powerW,230,"reference active watts preserve phase")
    close(p.voltageRMS,230,"reference voltage RMS")
    close(p.currentRMS,2,"reference current RMS")
    close(p.apparentVA,460,"apparent VA separate from active watts")
    close(p.powerFactor!,0.5,"reference PF phase aware")
    check(!cfg.calibrated && p.quality == "reference_estimate_NOT_calibrated","reference calculation never certifies calibration")
    let zero = try referencePower(v,Array(repeating:18,count:640),config:cfg)
    close(zero.powerW,0,"known zero offset produces zero current power")
    check(zero.powerFactor == nil,"no misleading PF for no current")
    var reversed = cfg;reversed.currentSign = -1
    let negative = try referencePower(v,i,config:reversed)
    close(negative.powerW,-230,"negative reference power not rectified")
    let fitted = try fitReferencePower(v,i,config:cfg,measuredPower:400,measuredVoltage:240)
    let after = try referencePower(v,i,config:fitted)
    close(after.powerW,400,"single point power gain fit")
    close(after.voltageRMS,240,"optional measured voltage gain fit")
    check(!fitted.calibrated,"gain fit cannot promote calibration flag")
    let powerOnly = try fitReferencePower(v,i,config:cfg,measuredPower:350,measuredVoltage:nil)
    close(powerOnly.voltageScale,cfg.voltageScale,"power-only fit preserves voltage scale")
    do { _ = try fitReferencePower(v,Array(repeating:18,count:640),config:cfg,measuredPower:100,measuredVoltage:nil);check(false,"zero signal fit rejected") } catch { checks += 1 }
    do { _ = try fitReferencePower(v,i,config:reversed,measuredPower:100,measuredVoltage:nil);check(false,"negative signal fit rejected") } catch { checks += 1 }
    do { _ = try fitReferencePower(v,i,config:cfg,measuredPower:Double.nan,measuredVoltage:nil);check(false,"NaN reference rejected") } catch { checks += 1 }
    do { _ = try referencePower(Array(v.dropLast()),i,config:cfg);check(false,"misaligned channel lengths rejected") } catch { checks += 1 }
    var clipped = i;clipped[0] = 40000
    do { _ = try referencePower(v,clipped,config:cfg);check(false,"invalid ADC range rejected") } catch { checks += 1 }
    var window = PowerWindow();window.append(100,points:128);window.append(400,points:64)
    close(window.average!,200,"per-second watts weighted by received points")
    window.append(Double.nan,points:128);close(window.average!,200,"invalid watts excluded")
    window.reset();check(window.average == nil,"gaps cannot carry a previous power window")
    print("PASS TOTAL: \(checks) checks including active watts, offsets, phase and single-point reference fitting.")
}
