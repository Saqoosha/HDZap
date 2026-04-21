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
    uid[0] &= 0xFE // unicast MAC invariant (IEEE 802 bit0 = multicast)
    return uid
}

func formatUID(_ uid: [UInt8]) -> String {
    uid.map { String(format: "%02X", $0) }.joined(separator: ":")
}

/// Parse a "AA:BB:CC:DD:EE:FF" string into the raw 6 bytes the user typed.
/// Does NOT clear the multicast bit — call `normalizeUID` if you want the
/// value actually sent over the wire. Keeping the two steps separate lets
/// the UI display the normalized result (and any bit0 change) back to the
/// user rather than silently mutating their input.
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
    return .success(uid)
}

/// Enforce unicast MAC invariant on a 6-byte UID. Bit 0 of the first byte
/// must be zero or `esp_wifi_set_mac` on the firmware side will reject it.
func normalizeUID(_ uid: [UInt8]) -> [UInt8] {
    var out = uid
    if !out.isEmpty { out[0] &= 0xFE }
    return out
}
