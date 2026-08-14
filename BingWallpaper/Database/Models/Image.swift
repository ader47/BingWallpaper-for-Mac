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
    
    @MainActor
    func loadFromDisk() async throws -> Data {
        let downloadPath = downloadPath
        let wallpaperDirectory = FileHandler.wallpaperDirectory()
        return try await Task.detached(priority: .userInitiated) {
            try FileHandler.loadImageDataFromDisk(
                at: downloadPath,
                wallpaperDirectory: wallpaperDirectory
            )
        }.value
    }
    
    @MainActor
    func downloadAndSaveToDisk() async throws {
        guard let descriptor else {
            throw Error.missingDescriptor
        }
        let downloadPath = downloadPath
        let wallpaperDirectory = FileHandler.wallpaperDirectory()
        let imageData = try await DownloadManager.downloadImage(from: descriptor.imageUrl)
        try await Task.detached(priority: .utility) {
            try FileHandler.saveImageDataToDisk(
                imageData: imageData,
                toUrl: downloadPath,
                wallpaperDirectory: wallpaperDirectory
            )
        }.value
    }
    
    static func isSavedToDisk(descriptor: ImageDescriptor) -> Bool {
        return descriptor.image.isOnDisk()
    }
    
    func isOnDisk() -> Bool {
        return FileHandler.wallpaperFileExists(at: downloadPath)
    }

    @MainActor
    func isValidOnDisk() async -> Bool {
        let downloadPath = downloadPath
        let wallpaperDirectory = FileHandler.wallpaperDirectory()
        return await Task.detached(priority: .utility) {
            FileHandler.wallpaperFileIsValid(
                at: downloadPath,
                wallpaperDirectory: wallpaperDirectory
            )
        }.value
    }
}
