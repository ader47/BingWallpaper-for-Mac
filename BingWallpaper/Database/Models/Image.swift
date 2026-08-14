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
    
    let downloadPath: URL
    private weak var descriptor: ImageDescriptor?
    
    init(descriptor: ImageDescriptor) {
        self.descriptor = descriptor
        let fileName: String
        if let marketCode = descriptor.marketCode {
            fileName = marketCode + "_" + descriptor.startDate + ".jpg"
        } else {
            // Keep the legacy name for automatic/network-location images.
            fileName = descriptor.startDate + ".jpg"
        }
        self.downloadPath = FileHandler.defaultBingWallpaperDirectory().appendingPathComponent(fileName)
    }
    
    func loadFromDisk() async throws -> Data {
        return try Data(contentsOf: downloadPath)
    }
    
    func downloadAndSaveToDisk() async throws {
        guard let descriptor else {
            throw Error.missingDescriptor
        }
        let imageData = try await DownloadManager.downloadBinary(from: descriptor.imageUrl)
        try FileHandler.saveImageDataToDisk(imageData: imageData, toUrl: downloadPath)
    }
    
    static func isSavedToDisk(descriptor: ImageDescriptor) -> Bool {
        return descriptor.image.isOnDisk()
    }
    
    func isOnDisk() -> Bool {
        return FileManager.default.fileExists(atPath: downloadPath.relativePath)
    }
}
