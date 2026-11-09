//
//  HelperInstallerTests.swift
//  Only the install decision; install() shows the authorization dialog and must never run in tests.
//

import Foundation
import XCTest

@testable import time_scramble

final class HelperInstallerTests: XCTestCase {
    private let bundled = HelperInstaller.bundledHelperURL(in: .main)

    func test_bundledHelper_isEmbeddedInTheApp() {
        XCTAssertTrue(bundled.path.hasSuffix("time-scramble.app/Contents/Library/LaunchServices/com.focustimescrambler.helper"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundled.path))
    }

    func test_missingInstalledHelper_needsInstall() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertTrue(HelperInstaller.needsInstall(installed: missing, bundled: bundled))
    }

    func test_sameVersion_needsNoInstall() {
        XCTAssertFalse(HelperInstaller.needsInstall(installed: bundled, bundled: bundled))
    }

    func test_differentVersion_needsInstall() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = directory.appendingPathComponent("Old.bundle")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let plist: [String: Any] = ["CFBundleIdentifier": "com.focustimescrambler.helper", "CFBundleVersion": "0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        XCTAssertTrue(HelperInstaller.needsInstall(installed: bundle, bundled: bundled))
    }

    func test_installFailure_isHumanReadable() {
        XCTAssertTrue(HelperInstaller.InstallError.failed.localizedDescription.hasPrefix("Could not install the system helper."))
    }
}
