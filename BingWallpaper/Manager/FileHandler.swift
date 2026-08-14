import Foundation
import ImageIO
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.FileHandler.rawValue
)

class FileHandler {
    static func usersPictureDirectory() -> String {
        guard let picturesDirectory = NSSearchPathForDirectoriesInDomains(.picturesDirectory, .userDomainMask, true).first else {
            logger.error("Couldn't find picture directory of user")
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        
        return picturesDirectory
    }
    
    static func defaultBingWallpaperDirectory() -> String {
        return usersPictureDirectory() + "/bing-wallpapers/"
    }
    
    static func defaultBingWallpaperDirectory() -> URL {
        return URL(fileURLWithPath: defaultBingWallpaperDirectory(), isDirectory: true)
    }

    static func wallpaperDirectory() -> URL {
        return Settings().imageDownloadPath
    }

    @discardableResult
    static func withWallpaperDirectoryAccess<T>(_ operation: (URL) throws -> T) rethrows -> T {
        let directory = wallpaperDirectory()
        let didStartAccess = directory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                directory.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(directory)
    }
    
    static func createWallpaperFolderIfNeeded() {
        do {
            try withWallpaperDirectoryAccess { directory in
                if FileManager.default.fileExists(atPath: directory.path) { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            logger.error("Failed to create bing-wallpapers folder with error: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    static func saveImageDataToDisk(imageData: Data, toUrl: URL) throws {
        try withWallpaperDirectoryAccess { _ in
            try imageData.write(to: toUrl, options: .atomic)
        }
    }

    static func loadImageDataFromDisk(at url: URL) throws -> Data {
        return try withWallpaperDirectoryAccess { _ in
            try Data(contentsOf: url)
        }
    }

    static func wallpaperFileExists(at url: URL) -> Bool {
        return withWallpaperDirectoryAccess { _ in
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        }
    }
    
    static func getSavedImages() -> [URL] {
        do {
            return try withWallpaperDirectoryAccess { directory in
                try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            }
        } catch {
            logger.error("Failed to list saved images: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
    
    static func removeImageFromDisk(imagePath: URL) {
        do {
            return try withWallpaperDirectoryAccess { _ in
                try FileManager.default.removeItem(at: imagePath)
            }
        } catch {
            logger.error("Failed to remove image at \(imagePath.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
    }
    
    static func deleteOldImages(
        oldestDateStringToKeep: String,
        preservingFileNames: Set<String> = []
    ) {
        getSavedImages()
            .filter { imageUrl in
                guard preservingFileNames.contains(imageUrl.lastPathComponent) == false else {
                    return false
                }
                let fileName = imageUrl.deletingPathExtension().lastPathComponent
                let dateString = String(fileName.suffix(8))
                return dateString.count == 8 &&
                    dateString.allSatisfy(\.isNumber) &&
                    dateString <= oldestDateStringToKeep
            }
            .forEach { removeImageFromDisk(imagePath: $0) }
    }
    
    static func savePkgInstallerToDisk(pkgInstaller: Data, appVersion: String) -> URL? {
        let temporaryDirectoryUrl = pkgInstallerPathUrl(appVersion: appVersion)
        do {
            try pkgInstaller.write(to: temporaryDirectoryUrl, options: .atomic)
        } catch {
            logger.error("Failed to save pkg installer to disk with error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        
        return temporaryDirectoryUrl
    }
    
    static func pkgInstallerPathUrl(appVersion: String) -> URL {
        var temporaryDirectoryUrl = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        temporaryDirectoryUrl.appendPathComponent("BingWallpaper_" + appVersion + ".pkg")
        return temporaryDirectoryUrl
    }
}
