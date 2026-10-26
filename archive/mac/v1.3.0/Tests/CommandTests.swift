import Foundation

func runDeviceCommandChecks() {
    check(DeviceCommand.relayOn.bytes(encoding:.singleByte) == Data([0x21]),"relay-on exact single byte")
    check(DeviceCommand.relayOff.bytes(encoding:.singleByte) == Data([0x22]),"relay-off exact single byte")
    check(DeviceCommand.startData.bytes(encoding:.singleByte) == Data([0x23]),"start-data exact single byte")
    check(DeviceCommand.stopData.bytes(encoding:.singleByte) == Data([0x24]),"stop-data exact single byte")
    check(DeviceCommand.relayOn.bytes(encoding:.manualUTF8) == Data([0xef,0xbc,0x81]),"manual fullwidth exclamation UTF8")
    check(DeviceCommand.relayOff.bytes(encoding:.manualUTF8) == Data([0xe2,0x80,0x9c]),"manual left double quote UTF8")
    check(DeviceCommand.startData.bytes(encoding:.manualUTF8) == Data([0x23]) && DeviceCommand.stopData.bytes(encoding:.manualUTF8) == Data([0x24]),"data commands independent of relay encoding")
    check(DeviceCommand(rawValue:"reset") == nil && DeviceCommand(rawValue:"ip:192.168.1.1") == nil,"only four supported commands accepted")
    check(DeviceCommandEncoding(rawValue:"automatic") == nil,"automatic encoding probing unavailable")
    check(DeviceCommand.allCases.allSatisfy { c in [DeviceCommandEncoding.singleByte,.manualUTF8].allSatisfy { e in let bytes = c.bytes(encoding:e); return !bytes.contains(10) && !bytes.contains(13) } },"no appended CRLF")
    print("PASS: \(checks) checks including exact command bytes; no hardware commands sent.")
}
