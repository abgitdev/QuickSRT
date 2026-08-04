import Foundation
import XCTest
import QuickSRT

final class ProjectRootResolverTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/Applications/QuickSRT.app", isDirectory: true)
    private let supportURL = URL(fileURLWithPath: "/Library/Application Support/QuickSRT", isDirectory: true)
    private let bundledSupportURL = URL(fileURLWithPath: "/Applications/QuickSRT.app/Contents/Resources/QuickSRTSupport", isDirectory: true)
    private let desktopURL = URL(fileURLWithPath: "/Desktop/QuickSRT", isDirectory: true)

    func testEnvironmentOverrideIsUsedWhenNoBundledSupportExists() {
        let resolved = resolve(environmentRoot: "/Configured/QuickSRT", usableRoots: [])

        XCTAssertEqual(resolved.path, "/Configured/QuickSRT")
    }

    func testPresentBundledSupportCannotBeReplacedByEnvironmentOverride() {
        let resolved = ProjectRootResolver.resolve(
            environmentRoot: "/Attacker/Runtime",
            bundleURL: bundleURL,
            bundledSupportRoot: bundledSupportURL,
            applicationSupportRoot: supportURL,
            desktopRoot: desktopURL,
            isUsableRoot: { _ in false }
        )

        XCTAssertEqual(resolved, bundledSupportURL)
    }

    func testBundleAncestorIsPreferredForDevelopmentBuilds() {
        let repositoryURL = URL(fileURLWithPath: "/Workspace/QuickSRT", isDirectory: true)
        let appURL = repositoryURL.appendingPathComponent("App/QuickSRT.app", isDirectory: true)

        let resolved = ProjectRootResolver.resolve(
            environmentRoot: nil,
            bundleURL: appURL,
            bundledSupportRoot: bundledSupportURL,
            applicationSupportRoot: supportURL,
            desktopRoot: desktopURL,
            isUsableRoot: { $0.standardizedFileURL == repositoryURL.standardizedFileURL }
        )

        XCTAssertEqual(resolved.standardizedFileURL, repositoryURL.standardizedFileURL)
    }

    func testMissingInstalledSupportStillCannotFallBackToEnvironment() {
        let missingSupport = bundleURL.appendingPathComponent(
            "Contents/Resources/QuickSRTSupport",
            isDirectory: true
        )
        let resolved = ProjectRootResolver.resolve(
            environmentRoot: "/Attacker/Runtime",
            bundleURL: bundleURL,
            bundledSupportRoot: missingSupport,
            applicationSupportRoot: supportURL,
            desktopRoot: desktopURL,
            isUsableRoot: { _ in false }
        )

        XCTAssertEqual(resolved, missingSupport)
    }

    func testApplicationSupportIsPreferredForInstalledApp() {
        let resolved = resolve(environmentRoot: nil, usableRoots: [supportURL])

        XCTAssertEqual(resolved, supportURL)
    }

    func testSignedBundledSupportIsPreferredForInstalledApp() {
        let resolved = resolve(environmentRoot: nil, usableRoots: [bundledSupportURL, supportURL])

        XCTAssertEqual(resolved, bundledSupportURL)
    }

    func testDesktopRootRemainsCompatibleFallback() {
        let resolved = resolve(environmentRoot: nil, usableRoots: [desktopURL])

        XCTAssertEqual(resolved, desktopURL)
    }

    func testMissingRuntimeDefaultsToApplicationSupport() {
        let resolved = resolve(environmentRoot: nil, usableRoots: [])

        XCTAssertEqual(resolved, supportURL)
    }

    private func resolve(environmentRoot: String?, usableRoots: Set<URL>) -> URL {
        let bundledSupportRoot = usableRoots.contains(bundledSupportURL)
            ? bundledSupportURL
            : nil
        return ProjectRootResolver.resolve(
            environmentRoot: environmentRoot,
            bundleURL: bundleURL,
            bundledSupportRoot: bundledSupportRoot,
            applicationSupportRoot: supportURL,
            desktopRoot: desktopURL,
            isUsableRoot: { usableRoots.contains($0) }
        )
    }
}
