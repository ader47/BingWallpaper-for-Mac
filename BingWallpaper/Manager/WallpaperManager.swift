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

    @MainActor
    @objc func activeWorkspaceDidChange() {
        updateWallpaperIfNeeded(forceRefresh: false)
    }

    @MainActor
    @objc func workspaceDidWake() {
        updateWallpaperIfNeeded(forceRefresh: false)
    }

    @MainActor
    @objc func screenParametersDidChange() {
        updateWallpaperIfNeeded(forceRefresh: false)
    }
    
    @MainActor
    func setWallpaper(descriptor: ImageDescriptor) {
        imageDescriptor = descriptor
        updateWallpaperIfNeeded(forceRefresh: false)
    }

    @MainActor
    func refreshWallpaper(force: Bool = false) {
        updateWallpaperIfNeeded(forceRefresh: force)
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

    @MainActor
    static func currentWallpaperIdentifier(forDisplayIdentifier identifier: String) -> String? {
        guard let screen = NSScreen.screens.first(where: { displayIdentifier(for: $0) == identifier }),
              let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        return Database.instance.allImageDescriptors().first(where: {
            wallpaperURL(currentURL, matches: $0.image.downloadPath)
        })?.wallpaperIdentifier
    }

    @MainActor
    private func updateWallpaperIfNeeded(forceRefresh: Bool) {
        guard imageDescriptor != nil else { return }
        let workspace = NSWorkspace.shared
        let mode = settings.wallpaperDisplayMode
        let selectedDisplayIDs = settings.selectedWallpaperDisplayIDs
        let downloadedDescriptors = Database.instance.allImageDescriptors()
            .filter { $0.image.isOnDisk() }
        var profiles = settings.wallpaperDisplayProfiles
        var profilesDidChange = false
        
        FileHandler.withWallpaperDirectoryAccess { _ in
            for screen in NSScreen.screens {
                let displayIdentifier = Self.displayIdentifier(for: screen)
                guard Self.shouldApplyWallpaper(
                    toDisplayIdentifier: displayIdentifier,
                    isMainDisplay: Self.displayID(for: screen) == CGMainDisplayID(),
                    mode: mode,
                    selectedDisplayIDs: selectedDisplayIDs
                ) else {
                    continue
                }

                var profile = displayIdentifier.flatMap { profiles[$0] }
                    ?? WallpaperDisplayProfile()
                guard let descriptor = desiredDescriptor(
                    for: &profile,
                    from: downloadedDescriptors
                ) else {
                    continue
                }
                if let displayIdentifier {
                    if profile.isDefault {
                        if profiles.removeValue(forKey: displayIdentifier) != nil {
                            profilesDidChange = true
                        }
                    } else if profiles[displayIdentifier] != profile {
                        profiles[displayIdentifier] = profile
                        profilesDidChange = true
                    }
                }
                let imageUrl = descriptor.image.downloadPath

                guard forceRefresh ||
                    !Self.wallpaperURL(workspace.desktopImageURL(for: screen), matches: imageUrl) else {
                    continue
                }

                do {
                    try workspace.setDesktopImageURL(imageUrl, for: screen, options: [:])
                } catch {
                    logger.error("Failed to set desktop image: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if profilesDidChange {
            settings.wallpaperDisplayProfiles = profiles
        }
    }

    private func desiredDescriptor(
        for profile: inout WallpaperDisplayProfile,
        from downloadedDescriptors: [ImageDescriptor]
    ) -> ImageDescriptor? {
        if profile.pinMode == .inherit,
           settings.pinnedWallpaperID != nil {
            return imageDescriptor
        }

        let effectiveMarketCode = profile.effectiveMarketCode(
            globalMarketCode: settings.bingMarketCode
        )
        if profile.pinMode == .pinned {
            if let pinnedWallpaperID = profile.pinnedWallpaperID,
               let pinnedDescriptor = downloadedDescriptors.first(where: {
                   $0.wallpaperIdentifier == pinnedWallpaperID
               }) {
                return pinnedDescriptor
            }

            let newestDescriptor = downloadedDescriptors
                .filter { $0.marketCode == effectiveMarketCode }
                .max()
            profile.pinnedWallpaperID = newestDescriptor?.wallpaperIdentifier
            return newestDescriptor
        }

        if profile.marketMode == .inherit,
           profile.pinMode == .inherit {
            return imageDescriptor
        }

        return downloadedDescriptors
            .filter { $0.marketCode == effectiveMarketCode }
            .max()
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
