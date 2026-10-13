import Foundation

/// The request owner supplies these checks for one immutable request. Revalidation
/// may await SQLite; the final check must be synchronous and perform no I/O.
struct EluV1TransportAuthority: Sendable {
    let revalidate: @Sendable () async -> Bool
    let isCurrent: @Sendable () -> Bool
}

enum EluV1BoundTransportError: Error, Equatable {
    case staleAuthority
    case occupied
}

protocol EluV1AuthorizedFlagTransport: EluV1FlagTransport {
    func send(endpoint: URL, requestBody: Data, authority: EluV1TransportAuthority) async throws -> Data
}

protocol EluV1AuthorizedBatchTransport: EluV1BatchHTTPTransport {
    func send(_ request: EluV1BatchHTTPRequest, authority: EluV1TransportAuthority) async throws -> EluV1BatchHTTPResponse
}

/// All generations of a channel share the same concrete transport. This wrapper
/// rotates only the authority; it cannot create another physical transport slot.
struct EluV1BoundBatchTransport: EluV1BatchHTTPTransport {
    let transport: any EluV1AuthorizedBatchTransport
    let authority: EluV1TransportAuthority

    func send(_ request: EluV1BatchHTTPRequest) async throws -> EluV1BatchHTTPResponse {
        try await transport.send(request, authority: authority)
    }
}

final class EluV1PhysicalTransportSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false

    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !occupied else { return false }
        occupied = true
        return true
    }

    func release() {
        lock.lock(); occupied = false; lock.unlock()
    }
}
