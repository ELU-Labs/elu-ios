import Foundation

/// Length-preserving replay masks, identical to the web rule. Every UTF-16 code
/// unit that is not whitespace becomes `*`; whitespace is kept. Inputs become one
/// `*` per UTF-16 unit. Callers pass a transient value and keep only the result:
/// the original text never enters a snapshot, encoder, buffer or log.
enum EluNativeMaskText {
    /// Engine text limit, in UTF-8 bytes.
    static let maximumBytes = 4_096
    static let star: UInt16 = 0x2A

    /// The 25 code units of ECMAScript `\s`. Platform whitespace predicates
    /// differ from this set (NEL and ZWSP are starred, BOM is kept).
    static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0009 ... 0x000D, 0x0020, 0x00A0, 0x1680, 0x2000 ... 0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Stops before the output's UTF-8 size would exceed `maximumBytes`, so at
    /// most `maximumBytes` source units are visited however long the text is.
    static func maskText(_ text: String) -> String {
        var output: [UInt16] = []
        var bytes = 0
        for unit in text.utf16 {
            let kept = isWhitespace(unit) ? unit : star
            let size = kept < 0x80 ? 1 : (kept < 0x800 ? 2 : 3)
            guard bytes + size <= maximumBytes else { break }
            output.append(kept); bytes += size
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// `length` is the value's UTF-16 length; the value itself is never needed.
    static func maskInput(utf16Length length: Int) -> String {
        String(repeating: "*", count: min(max(length, 0), maximumBytes))
    }

    /// True when every unit is `*` or whitespace, including the empty string.
    /// Such text cannot be told apart from masked text on the wire.
    static func isMaskShaped(_ text: String) -> Bool {
        text.utf16.allSatisfy { $0 == star || isWhitespace($0) }
    }

    static func isInputMask(_ value: String) -> Bool {
        value.utf16.allSatisfy { $0 == star }
    }
}
