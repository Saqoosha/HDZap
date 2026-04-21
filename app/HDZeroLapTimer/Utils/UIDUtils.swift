import Foundation
import CryptoKit

enum UIDMode {
    case bindPhrase(String)
    case manualUID([UInt8])
    case newPairing
}

func uidFromBindPhrase(_ phrase: String) -> [UInt8] {
    let input = "-DMY_BINDING_PHRASE=\"\(phrase)\""
    let digest = Insecure.MD5.hash(data: Data(input.utf8))
    var uid = Array(digest.prefix(6))
    uid[0] &= 0xFE // clear bit 0 for unicast MAC
    return uid
}

func formatUID(_ uid: [UInt8]) -> String {
    uid.map { String(format: "%02X", $0) }.joined(separator: ":")
}

func parseUID(_ string: String) -> [UInt8]? {
    let parts = string.split(separator: ":")
    guard parts.count == 6 else { return nil }
    var uid: [UInt8] = []
    for part in parts {
        guard let byte = UInt8(part, radix: 16) else { return nil }
        uid.append(byte)
    }
    return uid
}
