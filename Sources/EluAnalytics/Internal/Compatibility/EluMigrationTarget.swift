import Foundation

enum EluMigrationAdoptionResult: Equatable, Sendable {
    case adopted
    case alreadyAdopted
}

/// What the target reports after it has installed a checkpoint. The
/// coordinator compares every field against the checkpoint it wrote before
/// it declares the migration verified.
struct EluMigrationReadBack: Equatable, Sendable {
    var checkpointId: String
    var identity: EluMigrationIdentitySnapshot
    var context: EluMigrationContextSnapshot
    var stream: EluMigrationStreamSnapshot
    var importedQueueRecordCount: Int

    init(
        checkpointId: String,
        identity: EluMigrationIdentitySnapshot,
        context: EluMigrationContextSnapshot,
        stream: EluMigrationStreamSnapshot,
        importedQueueRecordCount: Int
    ) {
        self.checkpointId = checkpointId
        self.identity = identity
        self.context = context
        self.stream = stream
        self.importedQueueRecordCount = importedQueueRecordCount
    }
}

enum EluMigrationTargetError: Error, Equatable, Sendable {
    case unavailable
    case checkpointConflict
}

/// The runtime state that receives the imported checkpoint.
///
/// `adopt` installs the snapshot and the checkpoint id in one atomic step.
/// Calling it again with the same checkpoint id must change nothing and
/// return `alreadyAdopted`; a different id while one is already installed
/// must throw `checkpointConflict` rather than overwrite. This is what lets
/// a retry after a crash neither change identity nor import the same queue
/// prefix twice.
protocol EluMigrationTarget: Sendable {
    func adopt(_ checkpoint: EluMigrationCheckpoint) throws -> EluMigrationAdoptionResult
    func readBack() throws -> EluMigrationReadBack?
}
