import Foundation

enum DeviceCommandEncoding: String {
    case singleByte = "singleByte"
    case manualUTF8 = "manualUTF8"
}

/// The supplied YS8000 manual prints U+FF01 and U+201C for relay commands.
/// Single-byte 21/22 is an explicit selectable interpretation, not hardware verified.
/// Never append CR/LF, concatenate commands, or retry a relay command automatically.
enum DeviceCommand: String, CaseIterable {
    case relayOn, relayOff, startData, stopData
    var title: String {
        switch self {
        case .relayOn: return "接通供电（继电器打开）"
        case .relayOff: return "断开供电（继电器关闭）"
        case .startData: return "开始发送数据"
        case .stopData: return "停止发送数据"
        }
    }
    func bytes(encoding: DeviceCommandEncoding) -> Data {
        switch self {
        case .startData: return Data([0x23])
        case .stopData: return Data([0x24])
        case .relayOn: return encoding == .singleByte ? Data([0x21]) : Data("！".utf8)
        case .relayOff: return encoding == .singleByte ? Data([0x22]) : Data("“".utf8)
        }
    }
}

func deviceCommandHex(_ data: Data) -> String { data.map { String(format:"%02X",$0) }.joined(separator:" ") }
