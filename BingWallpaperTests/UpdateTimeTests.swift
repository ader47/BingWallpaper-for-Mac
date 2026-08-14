//
//  UpdateTimeTests.swift
//  BingWallpaperTests
//
//  Created by Laurenz Lazarus on 31.10.22.
//

import XCTest
@testable import BingWallpaper

final class UpdateTimeTests: XCTestCase {
    
    override func setUpWithError() throws { }
    
    override func tearDownWithError() throws { }
    
    func testUpdateAfter3h() {
        let before3h = Date(timeIntervalSinceNow: -3 * 3600)
        let settings = Settings()
        settings.lastUpdate = before3h
        
        XCTAssertTrue(UpdateScheduleManager.isUpdateNecessary())
    }
    
    func testUpdateAfer2h() {
        let before2h = Date(timeIntervalSinceNow: -2 * 3600)
        let settings = Settings()
        settings.lastUpdate = before2h
        
        XCTAssertFalse(UpdateScheduleManager.isUpdateNecessary())
    }

}

final class BingMarketTests: XCTestCase {
    func testAutomaticMarketDoesNotAddMarketQuery() {
        let url = DownloadManager.imageArchiveUrl(numberOfImages: 8, marketCode: nil)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        XCTAssertNil(queryItems?.first(where: { $0.name == "mkt" }))
    }

    func testExplicitMarketAddsMarketQuery() {
        let url = DownloadManager.imageArchiveUrl(numberOfImages: 8, marketCode: "zh-CN")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        XCTAssertEqual(queryItems?.first(where: { $0.name == "mkt" })?.value, "zh-CN")
    }

    func testSupportedMarketCodesAreUniqueAndWellFormed() {
        let codes = BingMarketOption.supportedCodes

        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertTrue(codes.allSatisfy { $0.range(of: "^[a-z]{2}-[A-Z]{2}$", options: .regularExpression) != nil })
    }
}

final class DownloadValidationTests: XCTestCase {
    func testRejectsHttpErrorStatus() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/image.jpg")!,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )!

        XCTAssertThrowsError(try DownloadManager.validateHttpResponse(response))
    }

    func testRecognizesFlatInstallerPackageMagic() {
        XCTAssertTrue(DownloadManager.isValidInstallerPackage(Data([0x78, 0x61, 0x72, 0x21, 0x00])))
        XCTAssertFalse(DownloadManager.isValidInstallerPackage(Data("<html>not a package</html>".utf8)))
    }

    func testRejectsInvalidImageData() {
        XCTAssertFalse(DownloadManager.isValidImageData(Data("<html>not an image</html>".utf8)))
    }

    func testSha256ChecksumVerification() {
        let packageData = Data("abc".utf8)
        let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  BingWallpaper.pkg\n"

        XCTAssertTrue(AppUpdateManager.verifyChecksum(packageData: packageData, checksumText: checksum))
        XCTAssertFalse(AppUpdateManager.verifyChecksum(packageData: packageData, checksumText: String(repeating: "0", count: 64)))
    }
}

final class ImageDirectorySettingsTests: XCTestCase {
    func testSecurityScopedBookmarkRoundTrip() throws {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BingWallpaperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = Settings(defaults: defaults)
        try settings.setImageDownloadPath(directory)

        XCTAssertEqual(settings.imageDownloadPath.standardizedFileURL, directory.standardizedFileURL)
    }
}

final class WallpaperManagerTests: XCTestCase {
    func testEquivalentFileURLsMatch() {
        let currentURL = URL(fileURLWithPath: "/tmp/wallpapers/../wallpapers/current.jpg")
        let desiredURL = URL(fileURLWithPath: "/tmp/wallpapers/current.jpg")

        XCTAssertTrue(WallpaperManager.wallpaperURL(currentURL, matches: desiredURL))
    }

    func testDifferentFileURLsDoNotMatch() {
        let currentURL = URL(fileURLWithPath: "/tmp/wallpapers/previous.jpg")
        let desiredURL = URL(fileURLWithPath: "/tmp/wallpapers/current.jpg")

        XCTAssertFalse(WallpaperManager.wallpaperURL(currentURL, matches: desiredURL))
    }

    func testMissingCurrentURLDoesNotMatch() {
        let desiredURL = URL(fileURLWithPath: "/tmp/wallpapers/current.jpg")

        XCTAssertFalse(WallpaperManager.wallpaperURL(nil, matches: desiredURL))
    }

    func testAllDisplayModeTargetsEveryDisplay() {
        XCTAssertTrue(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: nil,
            isMainDisplay: false,
            mode: .all,
            selectedDisplayIDs: []
        ))
    }

    func testMainDisplayModeTargetsOnlyMainDisplay() {
        XCTAssertTrue(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "main",
            isMainDisplay: true,
            mode: .main,
            selectedDisplayIDs: []
        ))
        XCTAssertFalse(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "secondary",
            isMainDisplay: false,
            mode: .main,
            selectedDisplayIDs: []
        ))
    }

    func testSelectedDisplayModeTargetsOnlySelectedIdentifiers() {
        let selectedDisplayIDs: Set<String> = ["secondary"]

        XCTAssertTrue(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "secondary",
            isMainDisplay: false,
            mode: .selected,
            selectedDisplayIDs: selectedDisplayIDs
        ))
        XCTAssertFalse(WallpaperManager.shouldApplyWallpaper(
            toDisplayIdentifier: "main",
            isMainDisplay: true,
            mode: .selected,
            selectedDisplayIDs: selectedDisplayIDs
        ))
    }
}

final class WallpaperDisplaySettingsTests: XCTestCase {
    func testDefaultsToAllDisplays() {
        withSettings { settings in
            XCTAssertEqual(settings.wallpaperDisplayMode, .all)
            XCTAssertTrue(settings.selectedWallpaperDisplayIDs.isEmpty)
        }
    }

    func testPersistsSelectedDisplays() {
        withSettings { settings in
            settings.wallpaperDisplayMode = .selected
            settings.selectedWallpaperDisplayIDs = ["display-b", "display-a"]

            XCTAssertEqual(settings.wallpaperDisplayMode, .selected)
            XCTAssertEqual(settings.selectedWallpaperDisplayIDs, ["display-a", "display-b"])
        }
    }

    private func withSettings(_ operation: (Settings) -> Void) {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        operation(Settings(defaults: defaults))
    }
}

final class UpdateStatusTests: XCTestCase {
    func testStatusMenuTitles() {
        let base = WallpaperUpdateStatus(
            phase: .idle,
            lastSuccessAt: nil,
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            failure: nil,
            consecutiveFailures: 0
        )

        XCTAssertEqual(base.menuTitle, "Update Status: Up to Date")
        XCTAssertEqual(status(from: base, phase: .updating).menuTitle, "Update Status: Updating…")
        XCTAssertEqual(status(from: base, phase: .retrying).menuTitle, "Update Status: Failed — Retry Scheduled")
        XCTAssertEqual(status(from: base, phase: .failed).menuTitle, "Update Status: Failed")
    }

    func testRetryBackoffStartsAtThirtySecondsAndCapsAtThirtyMinutes() {
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 0), 30)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 1), 30)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 2), 60)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 3), 120)
        XCTAssertEqual(UpdateManager.retryInterval(forFailureCount: 20), 30 * 60)
    }

    func testManagerInitialStatusUsesPersistedLastSuccess() {
        let suiteName = "BingWallpaperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = Settings(defaults: defaults)
        settings.lastUpdate = expectedDate

        let manager = UpdateManager(settings: settings)

        XCTAssertEqual(manager.status.lastSuccessAt, expectedDate)
        XCTAssertEqual(manager.status.phase, .idle)
    }

    private func status(
        from status: WallpaperUpdateStatus,
        phase: WallpaperUpdatePhase
    ) -> WallpaperUpdateStatus {
        return WallpaperUpdateStatus(
            phase: phase,
            lastSuccessAt: status.lastSuccessAt,
            lastAttemptAt: status.lastAttemptAt,
            nextAttemptAt: status.nextAttemptAt,
            failure: status.failure,
            consecutiveFailures: status.consecutiveFailures
        )
    }
}

final class WallpaperImageInfoTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testParsesTitleCopyrightDateAndRegion() {
        let info = WallpaperImageInfo(
            description: "Mountain lake (© Example Photographer)",
            startDate: "20250102",
            marketCode: "en-US",
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(info.title, "Mountain lake")
        XCTAssertEqual(info.copyright, "© Example Photographer")
        XCTAssertEqual(info.date, "Jan 2, 2025")
        XCTAssertTrue(info.region.hasSuffix("(en-US)"))
    }

    func testKeepsParenthesesInsideTitle() {
        let info = WallpaperImageInfo(
            description: "Lake (North Shore) at dawn (© Example)",
            startDate: "20250102",
            marketCode: nil,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(info.title, "Lake (North Shore) at dawn")
        XCTAssertEqual(info.copyright, "© Example")
        XCTAssertEqual(info.region, "Automatic (Network Location)")
    }

    func testDescriptionWithoutTrailingCopyrightRemainsTitle() {
        let info = WallpaperImageInfo(
            description: "Lake on the North Shore",
            startDate: "not-a-date",
            marketCode: nil,
            locale: locale,
            timeZone: timeZone
        )

        XCTAssertEqual(info.title, "Lake on the North Shore")
        XCTAssertEqual(info.copyright, "")
        XCTAssertEqual(info.date, "not-a-date")
    }
}
