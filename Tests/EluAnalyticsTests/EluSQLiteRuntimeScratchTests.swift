import Darwin
import Foundation
import XCTest
@testable import EluAnalytics

final class EluSQLiteRuntimeScratchTests: XCTestCase {
    private static let scratchName = ".runtime-state-v1.scratch"
    private static let databaseName = "runtime-state-v1.sqlite3"

    func testOrphanedScratchFamiliesAreReclaimedWithoutChangingOwnedState() async throws {
        try await withDirectory { directory in
            let original = try await open(directory)
            let expected = try await original.snapshot()
            await original.close()
            let scratch = try makeScratch(directory)
            for base in ["inspection.sqlite3", "install.sqlite3"] {
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    try Data("incomplete abandoned scratch".utf8).write(to: scratch.appendingPathComponent(base + suffix))
                }
            }
            let unrelated = directory.appendingPathComponent("application-file")
            try Data("preserve".utf8).write(to: unrelated)
            let reopened = try await open(directory)
            let actual = try await reopened.snapshot()
            XCTAssertEqual(actual, expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
            XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserve".utf8))
            await reopened.close()
        }
    }

    func testScratchDirectorySymlinkIsRejectedWithoutTouchingItsTarget() async throws {
        try await withDirectory { directory in
            let target = directory.appendingPathComponent("application-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let file = target.appendingPathComponent("inspection.sqlite3")
            try Data("preserve target".utf8).write(to: file)
            let scratch = directory.appendingPathComponent(Self.scratchName)
            try FileManager.default.createSymbolicLink(at: scratch, withDestinationURL: target)
            await assertInvalidDirectory(directory)
            XCTAssertEqual(try Data(contentsOf: file), Data("preserve target".utf8))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.path), target.path)
        }
    }

    func testScratchFileLinksAndUnknownEntriesRejectCleanupBeforeDeletingAnyFile() async throws {
        for kind in ["symlink", "hardlink", "unknown", "directory"] {
            try await withDirectory { directory in
                let scratch = try makeScratch(directory)
                let recognized = scratch.appendingPathComponent("inspection.sqlite3")
                try Data("retained known bytes".utf8).write(to: recognized)
                let target = directory.appendingPathComponent("application-file")
                try Data("retained target".utf8).write(to: target)
                let entry = scratch.appendingPathComponent(kind == "unknown" ? "application-file" : "install.sqlite3")
                switch kind {
                case "symlink": try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
                case "hardlink": try FileManager.default.linkItem(at: target, to: entry)
                case "directory": try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false)
                default: try Data("retained unknown".utf8).write(to: entry)
                }
                await assertInvalidDirectory(directory)
                XCTAssertEqual(try Data(contentsOf: recognized), Data("retained known bytes".utf8), kind)
                XCTAssertEqual(try Data(contentsOf: target), Data("retained target".utf8), kind)
                XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path), kind)
            }
        }
    }

    func testConcurrentOpeningCannotCleanTheCurrentOwnersInspection() async throws {
        try await withDirectory { directory in
            let seeded = try await open(directory)
            await seeded.close()
            let pause = ScratchInspectionPause()
            let opening = Task { try await self.open(directory, faultInjector: pause) }
            let reached = await Task.detached { pause.reached.wait(timeout: .now() + 10) }.value
            defer { pause.resume.signal() }
            XCTAssertEqual(reached, .success)
            guard reached == .success else { return }
            let copy = directory.appendingPathComponent(Self.scratchName).appendingPathComponent("inspection.sqlite3")
            let originalCopy = try Data(contentsOf: copy)
            do {
                let other = try await open(directory)
                await other.close()
                XCTFail("A competing owner must not acquire the scratch directory")
            } catch {
                XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict)
            }
            XCTAssertEqual(try Data(contentsOf: copy), originalCopy)
            pause.resume.signal()
            let owner = try await opening.value
            await owner.close()
        }
    }

    func testExternalStoreLeasePreventsOrphanCleanup() async throws {
        try await withDirectory { directory in
            let scratch = try makeScratch(directory)
            let orphan = scratch.appendingPathComponent("inspection.sqlite3")
            try Data("leased bytes".utf8).write(to: orphan)
            let lock = directory.appendingPathComponent(".runtime-state-v1.lock")
            let descriptor = lock.path.withCString { Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            do {
                let queue = try await open(directory)
                await queue.close()
                XCTFail("An external lease must prevent scratch cleanup")
            } catch {
                XCTAssertEqual(error as? EluRuntimeQueueError, .ownershipConflict)
            }
            XCTAssertEqual(try Data(contentsOf: orphan), Data("leased bytes".utf8))
        }
    }

    #if os(macOS)
    func testAbruptProcessExitDuringInspectionDoesNotAccumulateCopies() async throws {
        try await withDirectory { directory in
            let seeded = try await open(directory)
            let initial = try await seeded.snapshot()
            let versions = try EluVersionContext(runtime: EluVersionComponent(name: "elu-ios", version: "0.2.0"),
                facade: EluVersionComponent(name: "Elu", version: "1.0.0"), build: "scratch-test")
            _ = try await seeded.applyMutation(.setPersonProperties(set: ["retained": .bool(true)], setOnce: [:], unset: []),
                versions: versions, expectedGeneration: initial.generation)
            let expected = try await seeded.snapshot()
            let records = try await seeded.peek(maximumCount: 10, maximumBytes: 1_000_000)
            await seeded.close()
            let originalNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let originalFamily = try Dictionary(uniqueKeysWithValues: ["", "-wal", "-shm"].compactMap { suffix -> (String, Data)? in
                let file = directory.appendingPathComponent(Self.databaseName + suffix)
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                return (suffix, try Data(contentsOf: file))
            })
            for _ in 0..<3 {
                try runAbruptChild(directory, point: "inspection")
                let scratch = directory.appendingPathComponent(Self.scratchName)
                for (suffix, bytes) in originalFamily {
                    XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(Self.databaseName + suffix)), bytes)
                    XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent("inspection.sqlite3" + suffix)), bytes)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted(),
                    originalFamily.keys.map { "inspection.sqlite3" + $0 }.sorted())
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                    (originalNames + [Self.scratchName]).sorted())
            }
            let reopened = try await open(directory)
            let actual = try await reopened.snapshot()
            let actualRecords = try await reopened.peek(maximumCount: 10, maximumBytes: 1_000_000)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actualRecords, records)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.scratchName).path))
            await reopened.close()
        }
    }

    func testAbruptProcessExitBeforeInitialInstallReclaimsOneStagedFamily() async throws {
        try await withDirectory { directory in
            for _ in 0..<3 {
                try runAbruptChild(directory, point: "install")
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.databaseName).path))
                let scratch = directory.appendingPathComponent(Self.scratchName)
                let names = Set(try FileManager.default.contentsOfDirectory(atPath: scratch.path))
                XCTAssertTrue(names.contains("install.sqlite3"))
                XCTAssertTrue(names.isSubset(of: Set(["", "-wal", "-shm", "-journal"].map { "install.sqlite3" + $0 })))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                    [Self.scratchName, ".runtime-state-v1.lock"].sorted())
            }
            let queue = try await open(directory)
            let snapshot = try await queue.snapshot()
            XCTAssertEqual(snapshot.queuedCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.scratchName).path))
            await queue.close()
        }
    }

    /// Launched only by the tests above, in a separate process. _exit bypasses
    /// Swift defer/deinit and SQLite close exactly as abrupt termination does.
    func testAbruptExitChild() async throws {
        guard let path = ProcessInfo.processInfo.environment["ELU_SCRATCH_TEST_DIRECTORY"],
              let point = ProcessInfo.processInfo.environment["ELU_SCRATCH_TEST_POINT"] else { return }
        let queue = try await open(URL(fileURLWithPath: path), faultInjector: ScratchAbruptExit(point: point))
        await queue.close()
        XCTFail("The selected crash point was not reached")
    }

    private func runAbruptChild(_ directory: URL, point: String) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "EluAnalyticsTests.EluSQLiteRuntimeScratchTests/testAbruptExitChild",
            Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["ELU_SCRATCH_TEST_DIRECTORY"] = directory.path
        environment["ELU_SCRATCH_TEST_POINT"] = point
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output; child.standardError = output
        try child.run()
        let deadline = Date().addingTimeInterval(20)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        let log = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(child.terminationReason, .exit, log)
        XCTAssertEqual(child.terminationStatus, 73, log)
    }
    #endif

    private func open(_ directory: URL, faultInjector: (any EluRuntimeQueueFaultInjecting)? = nil) async throws -> EluSQLiteRuntimeQueue {
        try await EluSQLiteRuntimeQueue.open(directoryURL: directory, limits: EluRuntimeQueueLimits(),
            clock: { Date(timeIntervalSince1970: 1_786_147_200) }, anonymousIdGenerator: { "anon_scratch" },
            streamIdGenerator: { "stream_scratch" }, sessionIdGenerator: { "session_scratch" }, faultInjector: faultInjector)
    }

    private func assertInvalidDirectory(_ directory: URL) async {
        do {
            let queue = try await open(directory)
            await queue.close()
            XCTFail("Unrecognized scratch must fail closed")
        } catch { XCTAssertEqual(error as? EluRuntimeQueueError, .invalidDirectory) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.databaseName).path))
    }

    private func makeScratch(_ directory: URL) throws -> URL {
        let scratch = directory.appendingPathComponent(Self.scratchName, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        return scratch
    }

    private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elu-scratch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await operation(directory)
    }
}

private final class ScratchInspectionPause: EluRuntimeQueueFaultInjecting, @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func hit(_ point: EluRuntimeQueueFaultPoint) throws {
        if point == .afterInspectionCopy {
            reached.signal()
            guard resume.wait(timeout: .now() + 20) == .success else { throw EluRuntimeQueueError.databaseUnavailable }
        }
    }
}

#if os(macOS)
private struct ScratchAbruptExit: EluRuntimeQueueFaultInjecting {
    let point: String
    func hit(_ value: EluRuntimeQueueFaultPoint) throws {
        if (point == "inspection" && value == .afterInspectionCopy)
            || (point == "install" && value == .beforeInitialInstall) { Darwin._exit(73) }
    }
}
#endif
