/// Storage lifetime for analytics state. Explicit consent remains separate.
public enum EluPersistenceMode: Equatable, Sendable {
    /// Retain the owned SQLite store across SDK and application restarts.
    case persistent
    /// Keep analytics in memory until this SDK owner closes or the process exits.
    /// No analytics database, cache, or temporary database is written to disk.
    case memory
}
