import Foundation
import CryptoKit

enum UIDMode {
    case bindPhrase(String)
    case manualUID([UInt8])
    case newPairing
}

enum UIDParseError: Error, LocalizedError {
    case wrongPartCount(Int)
    case invalidHex(String)

    var errorDescription: String? {
        switch self {
        case .wrongPartCount(let got):
            return "UID must be 6 hex bytes separated by ':' (got \(got) parts)."
        case .invalidHex(let part):
            return "'\(part)' is not a valid hex byte (00–FF)."
        }
    }
}

func uidFromBindPhrase(_ phrase: String) -> [UInt8] {
    let input = "-DMY_BINDING_PHRASE=\"\(phrase)\""
    let digest = Insecure.MD5.hash(data: Data(input.utf8))
    var uid = Array(digest.prefix(6))
    uid[0] &= 0xFE // Must be even for unicast MAC (IEEE 802 bit0 = multicast).
    return uid
}

func formatUID(_ uid: [UInt8]) -> String {
    uid.map { String(format: "%02X", $0) }.joined(separator: ":")
}

func parseUID(_ string: String) -> Result<[UInt8], UIDParseError> {
    let parts = string.split(separator: ":")
    guard parts.count == 6 else { return .failure(.wrongPartCount(parts.count)) }
    var uid: [UInt8] = []
    for part in parts {
        guard let byte = UInt8(part, radix: 16) else {
            return .failure(.invalidHex(String(part)))
        }
        uid.append(byte)
    }
    // Enforce unicast MAC invariant so firmware's esp_wifi_set_mac won't reject.
    uid[0] &= 0xFE
    return .success(uid)
}
