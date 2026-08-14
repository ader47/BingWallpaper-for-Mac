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
