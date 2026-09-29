/// Controls whether new events may create or update a person profile.
/// This does not change consent or the remote capture policy.
public enum EluPersonProfilesMode: Equatable, Sendable {
    /// Anonymous activity stays profile-free until person processing is enabled.
    case identifiedOnly
    case always
    /// Person identity/property calls are ignored; groups and flag context remain available.
    case never
}
