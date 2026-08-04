import Foundation
import XCTest
@testable import QuickSRT

final class SRTOutputWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSRT-SRTOutputWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    func testSavesValidatedSRT() throws {
        let source = try write("source.srt", validSRT(text: "New subtitle"))
        let destination = directory.appendingPathComponent("output.srt")

        try SRTOutputWriter.save(validatedSource: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), validSRT(text: "New subtitle"))
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    func testAtomicallyReplacesExistingSRT() throws {
        let source = try write("source.srt", validSRT(text: "Replacement"))
        let destination = try write("output.srt", validSRT(text: "Previous"))

        try SRTOutputWriter.save(validatedSource: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), validSRT(text: "Replacement"))
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    func testAbsentApprovedDestinationCannotOverwriteFileCreatedBeforeCommit() throws {
        let source = try write("source.srt", validSRT(text: "Replacement"))
        let destination = directory.appendingPathComponent("output.srt")
        let approved = try OutputDestination.authorizingCurrentState(destination)
        let concurrent = validSRT(text: "Created later")
        try concurrent.write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SRTOutputWriter.save(validatedSource: source, to: approved)) { error in
            guard case QuickSRTError.outputDestinationChanged = error else {
                return XCTFail("Expected destination-change failure, got \(error).")
            }
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), concurrent)
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    func testApprovedExistingDestinationCannotOverwriteChangedFile() throws {
        let source = try write("source.srt", validSRT(text: "Replacement"))
        let destination = try write("output.srt", validSRT(text: "Approved previous"))
        let approved = try OutputDestination.authorizingCurrentState(destination)
        let concurrent = validSRT(text: "Changed later and made longer")
        try concurrent.write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SRTOutputWriter.save(validatedSource: source, to: approved)) { error in
            guard case QuickSRTError.outputDestinationChanged = error else {
                return XCTFail("Expected destination-change failure, got \(error).")
            }
        }

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), concurrent)
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    func testInvalidSourceNeverChangesExistingSRT() throws {
        let source = try write("source.srt", "not an srt")
        let previous = validSRT(text: "Previous")
        let destination = try write("output.srt", previous)

        XCTAssertThrowsError(try SRTOutputWriter.save(validatedSource: source, to: destination))

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), previous)
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    func testCommitFailurePreservesExistingSRTAndRemovesStagingFile() throws {
        let source = try write("source.srt", validSRT(text: "Replacement"))
        let previous = validSRT(text: "Previous")
        let destination = try write("output.srt", previous)

        XCTAssertThrowsError(
            try SRTOutputWriter.save(
                validatedSource: source,
                to: destination,
                commit: { _, _ in throw TestFailure.simulatedCommitFailure }
            )
        )

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), previous)
        XCTAssertTrue(temporaryArtifacts().isEmpty)
    }

    func testReadOnlyDestinationFailsWithoutLeavingTemporaryOutput() throws {
        let source = try write("source.srt", validSRT(text: "Replacement"))
        let readOnlyDirectory = directory.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: readOnlyDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: readOnlyDirectory.path
            )
        }
        let destination = readOnlyDirectory.appendingPathComponent("output.srt")

        XCTAssertThrowsError(try SRTOutputWriter.save(validatedSource: source, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let children = try FileManager.default.contentsOfDirectory(atPath: readOnlyDirectory.path)
        XCTAssertTrue(children.isEmpty)
    }

    func testRejectsNonMonotonicTimestamps() throws {
        let invalid = """
        1
        00:00:05,000 --> 00:00:06,000
        First

        2
        00:00:04,000 --> 00:00:07,000
        Second

        """
        let source = try write("source.srt", invalid)

        XCTAssertThrowsError(try SRTValidator.validate(source))
    }

    func testRejectsOverlappingTimestamps() throws {
        let invalid = """
        1
        00:00:01,000 --> 00:00:04,000
        First

        2
        00:00:03,500 --> 00:00:05,000
        Second

        """
        let source = try write("overlap.srt", invalid)

        XCTAssertThrowsError(try SRTValidator.validate(source))
    }

    func testAcceptsAdjacentTimestamps() throws {
        let valid = """
        1
        00:00:01,000 --> 00:00:04,000
        First

        2
        00:00:04,000 --> 00:00:05,000
        Second

        """
        let source = try write("adjacent.srt", valid)

        XCTAssertNoThrow(try SRTValidator.validate(source))
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func validSRT(text: String) -> String {
        """
        1
        00:00:00,000 --> 00:00:01,500
        \(text)

        """
    }

    private func temporaryArtifacts() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix(".quicksrt-") }
    }
}

private enum TestFailure: Error {
    case simulatedCommitFailure
}
