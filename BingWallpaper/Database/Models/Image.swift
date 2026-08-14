//
//  Image.swift
//  BingWallpaper
//
//  Created by Laurenz Lazarus on 23.03.24.
//

import Foundation

class Image {
    enum Error: Swift.Error {
        case missingDescriptor
    }
    
    let fileName: String
    private weak var descriptor: ImageDescriptor?

    var downloadPath: URL {
        return FileHandler.wallpaperDirectory().appendingPathComponent(fileName)
    }
    
    init(descriptor: ImageDescriptor) {
        self.descriptor = descriptor
        self.fileName = Self.fileName(
            startDate: descriptor.startDate,
            marketCode: descriptor.marketCode
        )
    }

    static func fileName(startDate: String, marketCode: String?) -> String {
        let safeDate = safeFileNameComponent(startDate, expectedDate: true)
        guard let marketCode else {
            // Keep the legacy name for automatic/network-location images.
            return safeDate + ".jpg"
        }
        let safeMarket = safeFileNameComponent(marketCode, expectedDate: false)
        return safeMarket + "_" + safeDate + ".jpg"
    }

    private static func safeFileNameComponent(_ value: String, expectedDate: Bool) -> String {
        let isExpectedValue = expectedDate
            ? ImageDescriptor.isValidBingDate(value)
            : BingMarketOption.supportedCodes.contains(value)
        guard isExpectedValue else {
            let encodedValue = value.utf8
                .prefix(64)
                .map { String(format: "%02x", $0) }
                .joined()
            return "invalid-" + (encodedValue.isEmpty ? "empty" : encodedValue)
        }
        return value
    }
    
    func loadFromDisk() async throws -> Data {
        return try FileHandler.loadImageDataFromDisk(at: downloadPath)
    }
    
    func downloadAndSaveToDisk() async throws {
        guard let descriptor else {
            throw Error.missingDescriptor
        }
        let imageData = try await DownloadManager.downloadImage(from: descriptor.imageUrl)
        try FileHandler.saveImageDataToDisk(imageData: imageData, toUrl: downloadPath)
    }
    
    static func isSavedToDisk(descriptor: ImageDescriptor) -> Bool {
        return descriptor.image.isOnDisk()
    }
    
    func isOnDisk() -> Bool {
        return FileHandler.wallpaperFileExists(at: downloadPath)
    }
}
