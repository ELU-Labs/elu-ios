import Foundation

/// Converts an `Error` into bounded, JSON-safe exception event properties.
/// Messages and identifiers are capped so a pathological error cannot exceed
/// the queue's record ceiling, and underlying-error chains are walked with a
/// length cap plus object identity so a self-referential chain cannot loop.
enum EluExceptionSerializer {
    static let eventName = "$exception"
    static let typeProperty = "$exception_type"
    static let messageProperty = "$exception_message"
    static let listProperty = "$exception_list"
    static let maximumMessageCodePoints = 1_024
    static let maximumChainLength = 8

    static func properties(for error: any Error) -> [String: EluJSONValue] {
        let entries: [EluJSONValue] = causeChain(error).map { link in
            var entry: [String: EluJSONValue] = [
                "type": .string(typeName(link)),
                "value": jsonString(message(link)),
                "module": jsonString(moduleName(link)),
            ]
            if isFoundationError(link) {
                let bridged = link as NSError
                entry["domain"] = .string(bounded(bridged.domain))
                entry["code"] = .integer(Int64(bridged.code))
            }
            return .object(entry)
        }
        return [
            typeProperty: .string(typeName(error)),
            messageProperty: jsonString(message(error)),
            listProperty: .array(entries),
        ]
    }

    private static func jsonString(_ value: String?) -> EluJSONValue {
        guard let value else { return .null }
        return .string(value)
    }

    /// Explicit properties win over the derived ones.
    static func command(
        for error: any Error,
        occurredAt: Date,
        versions: EluVersionContext,
        explicitProperties: [String: EluJSONValue] = [:]
    ) -> EluV1CaptureCommand {
        var merged = properties(for: error)
        for (key, value) in explicitProperties {
            merged[key] = value
        }
        return EluV1CaptureCommand(
            kind: .exception,
            name: eventName,
            occurredAt: occurredAt,
            properties: merged,
            versions: versions
        )
    }

    /// Truncates to a code-point budget without splitting a scalar. Swift
    /// strings are always well-formed Unicode, so no surrogate repair is needed.
    static func bounded(
        _ value: String,
        maximumCodePoints: Int = EluExceptionSerializer.maximumMessageCodePoints
    ) -> String {
        guard value.unicodeScalars.count > maximumCodePoints else { return value }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: value.unicodeScalars.prefix(maximumCodePoints))
        return String(scalars)
    }

    private static func causeChain(_ error: any Error) -> [any Error] {
        var chain: [any Error] = []
        var seen: Set<ObjectIdentifier> = []
        var current: (any Error)? = error
        while let link = current, chain.count < maximumChainLength {
            if let identity = objectIdentity(link) {
                guard seen.insert(identity).inserted else { break }
            }
            chain.append(link)
            current = underlyingError(link)
        }
        return chain
    }

    /// Only genuine Foundation error objects have stable identity; Swift
    /// value errors are boxed on every bridge, so the length cap bounds them.
    private static func objectIdentity(_ error: any Error) -> ObjectIdentifier? {
        guard isFoundationError(error) else { return nil }
        return ObjectIdentifier(error as NSError)
    }

    private static func underlyingError(_ error: any Error) -> (any Error)? {
        (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
    }

    private static func isFoundationError(_ error: any Error) -> Bool {
        type(of: error) is NSError.Type
    }

    private static func typeName(_ error: any Error) -> String {
        bounded(String(describing: type(of: error)))
    }

    /// The module component of the qualified type name, when there is one.
    private static func moduleName(_ error: any Error) -> String? {
        let qualified = String(reflecting: type(of: error))
        guard let separator = qualified.firstIndex(of: "."),
              separator > qualified.startIndex
        else {
            return nil
        }
        return bounded(String(qualified[..<separator]))
    }

    private static func message(_ error: any Error) -> String? {
        let raw: String
        if isFoundationError(error) {
            raw = (error as NSError).localizedDescription
        } else if let localized = error as? LocalizedError,
                  let description = localized.errorDescription
        {
            raw = description
        } else {
            raw = String(describing: error)
        }
        guard !raw.isEmpty else { return nil }
        return bounded(raw)
    }
}
