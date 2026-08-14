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
        let fileName: String
        if let marketCode = descriptor.marketCode {
            fileName = marketCode + "_" + descriptor.startDate + ".jpg"
        } else {
            // Keep the legacy name for automatic/network-location images.
            fileName = descriptor.startDate + ".jpg"
        }
        self.fileName = fileName
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
