import AppKit
import ColorSync
import Foundation
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Wallpaper.rawValue
)

struct WallpaperDisplayInfo {
    let identifier: String
    let title: String
    let isMain: Bool
}

class WallpaperManager {
    private var imageDescriptor: ImageDescriptor?
    private let settings = Settings()
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

    func refreshWallpaper() {
        updateWallpaperIfNeeded()
    }

    static func connectedDisplays() -> [WallpaperDisplayInfo] {
        return NSScreen.screens.compactMap { screen in
            guard let identifier = displayIdentifier(for: screen) else { return nil }
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            let isMain = displayID(for: screen) == CGMainDisplayID()
            let mainSuffix = isMain ? " — Main Display" : ""
            return WallpaperDisplayInfo(
                identifier: identifier,
                title: "\(screen.localizedName) (\(width)×\(height))\(mainSuffix)",
                isMain: isMain
            )
        }.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain {
                return lhs.isMain
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func shouldApplyWallpaper(
        toDisplayIdentifier identifier: String?,
        isMainDisplay: Bool,
        mode: WallpaperDisplayMode,
        selectedDisplayIDs: Set<String>
    ) -> Bool {
        switch mode {
        case .all:
            return true
        case .main:
            return isMainDisplay
        case .selected:
            guard let identifier else { return false }
            return selectedDisplayIDs.contains(identifier)
        }
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
        let mode = settings.wallpaperDisplayMode
        let selectedDisplayIDs = settings.selectedWallpaperDisplayIDs
        
        FileHandler.withWallpaperDirectoryAccess { _ in
            for screen in NSScreen.screens {
                guard Self.shouldApplyWallpaper(
                    toDisplayIdentifier: Self.displayIdentifier(for: screen),
                    isMainDisplay: Self.displayID(for: screen) == CGMainDisplayID(),
                    mode: mode,
                    selectedDisplayIDs: selectedDisplayIDs
                ) else {
                    continue
                }

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

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private static func displayIdentifier(for screen: NSScreen) -> String? {
        guard let displayID = displayID(for: screen),
              let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }
}
