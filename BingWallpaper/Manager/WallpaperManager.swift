import AppKit
import Foundation
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Wallpaper.rawValue
)

class WallpaperManager {
    private var imageDescriptor: ImageDescriptor?
    static let shared = WallpaperManager()
    
    private init() {
        setupObserver()
    }
    
    private func setupObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(WallpaperManager.activeWorkspaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(WallpaperManager.workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(WallpaperManager.screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc func activeWorkspaceDidChange() {
        updateWallpaperIfNeeded()
    }

    @objc func workspaceDidWake() {
        updateWallpaperIfNeeded()
    }

    @objc func screenParametersDidChange() {
        updateWallpaperIfNeeded()
    }
    
    func setWallpaper(descriptor: ImageDescriptor) {
        imageDescriptor = descriptor
        updateWallpaperIfNeeded()
    }

    static func wallpaperURL(_ currentURL: URL?, matches desiredURL: URL) -> Bool {
        guard let currentURL else { return false }

        if currentURL.isFileURL && desiredURL.isFileURL {
            return currentURL.standardizedFileURL.resolvingSymlinksInPath()
                == desiredURL.standardizedFileURL.resolvingSymlinksInPath()
        }

        return currentURL.absoluteURL == desiredURL.absoluteURL
    }
    
    private func updateWallpaperIfNeeded() {
        guard let descriptor = imageDescriptor else { return }
        let imageUrl = descriptor.image.downloadPath
        let workspace = NSWorkspace.shared
        
        FileHandler.withWallpaperDirectoryAccess { _ in
            for screen in NSScreen.screens {
                guard !Self.wallpaperURL(workspace.desktopImageURL(for: screen), matches: imageUrl) else {
                    continue
                }

                do {
                    try workspace.setDesktopImageURL(imageUrl, for: screen, options: [:])
                } catch {
                    logger.error("Failed to set desktop image: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
