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
    case invalidDecimal(String)
    case decimalOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .wrongPartCount(let got):
            return "UID must be 6 bytes (got \(got) parts). Use hex 60:D2:53:8A:B2:00 or decimal 96 210 83 138 178 0."
        case .invalidHex(let part):
            return "'\(part)' is not a valid hex byte (00–FF)."
        case .invalidDecimal(let part):
            return "'\(part)' is not a valid decimal number."
        case .decimalOutOfRange(let value):
            return "\(value) is out of range — decimal bytes must be 0–255."
        }
    }
}

func uidFromBindPhrase(_ phrase: String) -> [UInt8] {
    let input = "-DMY_BINDING_PHRASE=\"\(phrase)\""
    let digest = Insecure.MD5.hash(data: Data(input.utf8))
    return normalizeUID(Array(digest.prefix(6)))
}

func formatUID(_ uid: [UInt8]) -> String {
    uid.map { String(format: "%02X", $0) }.joined(separator: ":")
}

/// Format a UID as comma-separated decimal bytes — matches what the
/// HDZero goggle and the M5Stick LCD display (`%u,%u,%u,%u,%u,%u`).
/// Use this for the "Current UID" headline; pair it with `formatUID`
/// (hex) as a small caption for cross-checking against MAC tools.
func formatUIDDecimal(_ uid: [UInt8]) -> String {
    uid.map { String($0) }.joined(separator: ",")
}

/// Parse a UID string into the raw 6 bytes the user typed. Accepts two
/// formats because each corresponds to how a different device displays
/// the UID:
///
///   - Hex with colons: "60:D2:53:8A:B2:00"
///     Canonical MAC form; what the iOS app and M5Stick LCD both show.
///
///   - Decimal with spaces or commas: "96 210 83 138 178 0"
///     What the HDZero goggle shows natively (one byte per row, decimal).
///     Typing the goggle-displayed numbers should Just Work so the user
///     doesn't have to mentally convert base-10 ↔ base-16 for six bytes.
///
/// Format detection:
///   - Any ':' in the input forces hex (avoids treating the canonical
///     MAC form as six ambiguous decimals).
///   - Otherwise, any hex letter (a–f / A–F) in any token forces hex.
///   - Otherwise, the input is treated as decimal.
///
/// Does NOT clear the multicast bit — call `normalizeUID` if you want
/// the value actually sent over the wire. Keeping the two steps
/// separate lets the UI display the normalized result (and any bit0
/// change) back to the user rather than silently mutating their input.
func parseUID(_ string: String) -> Result<[UInt8], UIDParseError> {
    let tokens = string.split(
        whereSeparator: { $0 == ":" || $0 == "," || $0.isWhitespace }
    )
    guard tokens.count == 6 else { return .failure(.wrongPartCount(tokens.count)) }

    let useHex: Bool = {
        if string.contains(":") { return true }
        for token in tokens {
            for char in token where char.isHexDigit && !char.isNumber {
                // Hex letter (a–f / A–F) present — unambiguously hex.
                return true
            }
        }
        return false
    }()

    var uid: [UInt8] = []
    for token in tokens {
        let part = String(token)
        if useHex {
            guard let byte = UInt8(part, radix: 16) else {
                return .failure(.invalidHex(part))
            }
            uid.append(byte)
        } else {
            guard let value = Int(part, radix: 10) else {
                return .failure(.invalidDecimal(part))
            }
            guard value >= 0 && value <= 255 else {
                return .failure(.decimalOutOfRange(value))
            }
            uid.append(UInt8(value))
        }
    }
    return .success(uid)
}

/// Enforce the unicast MAC invariant on a 6-byte UID: bit 0 of the first
/// octet is the IEEE 802 multicast flag; `esp_wifi_set_mac` on the firmware
/// rejects any MAC with it set.
///
/// Requires a 6-byte input — other lengths indicate a logic error at the
/// caller (parseUID/uidFromBindPhrase both guarantee 6 bytes).
func normalizeUID(_ uid: [UInt8]) -> [UInt8] {
    precondition(uid.count == 6, "normalizeUID requires a 6-byte UID, got \(uid.count)")
    var out = uid
    out[0] &= 0xFE
    return out
}
