import Cocoa
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Menu.rawValue
)

class MenuController: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private let settings = Settings()
    private var descriptors = [ImageDescriptor]()
    private var selectedDescriptorIndex = 0
    private var imageSelectorView: ImageSelectorView!
    var updateManager: UpdateManager?
    private static let IMAGE_VIEW_TAG = 6
    private static let TEXT_VIEW_TAG = 7
    private static let UPDATE_STATUS_TAG = 8
    private static let REFRESH_IMAGES_TAG = 9
    private lazy var settingsWc = SettingsWc.instance()
    
    // MARK: - UI setup
    
    @MainActor
    func setup() {
        guard self.statusItem == nil && self.menu == nil else { return }
        if settings.hideMenuBarIcon == true { return }
        
        self.statusItem = createStatusBarItem()
        self.menu = createMenu()
        self.statusItem!.menu = menu
        
        showNewestImage()
        updateStatusMenu()
    }
    
    private func createStatusBarItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "BingWallpaper")
        }
        
        return statusItem
    }
    
    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 300
        
        let imageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        imageSelectorView = ImageSelectorView(frame: CGRect(x: 0, y: 0, width: menu.size.width, height: imageSelectorViewHeight(menu: menu)))
        imageSelectorView.leftButton.action = #selector(MenuController.imageSelectorViewLeftButtonAction)
        imageSelectorView.leftButton.target = self
        imageSelectorView.rightButton.action = #selector(MenuController.imageSelectorViewRightButtonAction)
        imageSelectorView.rightButton.target = self
        imageItem.view = imageSelectorView
        imageItem.tag = MenuController.IMAGE_VIEW_TAG
        menu.addItem(imageItem)
        
        menu.addItem(NSMenuItem.separator())

        let updateStatusItem = NSMenuItem(title: "Update Status", action: nil, keyEquivalent: "")
        updateStatusItem.tag = MenuController.UPDATE_STATUS_TAG
        menu.addItem(updateStatusItem)
        
        let refreshItem = NSMenuItem(title: "Refresh Images", action: #selector(refreshImages), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.tag = MenuController.REFRESH_IMAGES_TAG
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let appUpdateItem = NSMenuItem(title: "Check for app update", action: #selector(checkForAppUpdate), keyEquivalent: "")
        appUpdateItem.target = self
        menu.addItem(appUpdateItem)
        
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettingsWc), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        return menu
    }
    
    // MARK: - IBActions
    
    @MainActor
    @objc func showSettingsWc(sender: NSMenuItem?) {
        (settingsWc.contentViewController as! SettingsVc).delegate = self
        (settingsWc.contentViewController as! SettingsVc).updateManager = updateManager
        settingsWc.showWindow(self)
        settingsWc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @MainActor
    @objc func refreshImages(sender: NSMenuItem) {
        updateManager?.update()
    }
    
    @MainActor
    @objc func checkForAppUpdate(sender: NSMenuItem) {
        Task {
            await AppUpdateManager.checkForUpdate(notifyUserAboutNoNewVersion: true)
        }
    }
    
    @MainActor
    @objc func imageSelectorViewLeftButtonAction(_ sender: NSButton) {
        if descriptors.indices.contains(selectedDescriptorIndex - 1) == false {
            return
        }
        
        selectedDescriptorIndex = selectedDescriptorIndex - 1
        updateSelectedImage(newSelectedDescriptorIndex: selectedDescriptorIndex)
        updateImageSelectorView(newSelectedDescriptorIndex: selectedDescriptorIndex)
    }
    
    @MainActor
    @objc func imageSelectorViewRightButtonAction(_ sender: NSButton) {
        if descriptors.indices.contains(selectedDescriptorIndex + 1) == false {
            return
        }
        
        selectedDescriptorIndex = selectedDescriptorIndex + 1
        updateSelectedImage(newSelectedDescriptorIndex: selectedDescriptorIndex)
        updateImageSelectorView(newSelectedDescriptorIndex: selectedDescriptorIndex)
    }
    
    @MainActor
    @objc func imageInfoAction(_ sender: NSButton) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }
        imageActionsMenu(for: descriptor).popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY),
            in: sender
        )
    }

    @objc func openImageSource(_ sender: NSMenuItem) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }
        NSWorkspace.shared.open(descriptor.copyrightUrl)
    }

    @objc func revealImageInFinder(_ sender: NSMenuItem) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([descriptor.image.downloadPath])
    }

    @MainActor
    @objc func saveImageCopy(_ sender: NSMenuItem) {
        guard let descriptor = descriptors[safe: selectedDescriptorIndex] else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "Save Wallpaper Copy"
        savePanel.nameFieldStringValue = descriptor.image.fileName
        savePanel.allowedContentTypes = [.jpeg]
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }

        do {
            let data = try FileHandler.loadImageDataFromDisk(at: descriptor.image.downloadPath)
            let didStartAccess = destination.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    destination.stopAccessingSecurityScopedResource()
                }
            }
            try data.write(to: destination, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Save Wallpaper"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    
    // MARK: - Helper
    
    private func imageSelectorViewHeight(menu: NSMenu) -> CGFloat {
        let outerPadding = 5.0
        let buttonWidth = 15.0
        let innerPadding = 5.0
        let imageViewWidth = menu.size.width - outerPadding*2 - buttonWidth*2 - innerPadding*2
        let topMargin = 4.0
        return imageViewWidth / 16*9 + topMargin
    }
    
    private func updateSelectedImage(newSelectedDescriptorIndex: Int) {
        if let descriptor = descriptors[safe: newSelectedDescriptorIndex] {
            WallpaperManager.shared.setWallpaper(descriptor: descriptor)
        }
    }
    
    @MainActor
    private func updateImageSelectorView(newSelectedDescriptorIndex: Int) {
        guard let menu = menu else { return }
        
        let descriptor = descriptors[safe: newSelectedDescriptorIndex]
        Task {
            guard let descriptor else { return }
            do {
                let imageData = try await descriptor.image.loadFromDisk()
                await MainActor.run { [weak self] in
                    self?.imageSelectorView.imageView.image = NSImage(data: imageData)
                }
            } catch {
                logger.error("Failed to load image from disk: \(String(describing: descriptor), privacy: .public)")
            }
        }
        
        let textItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        textItem.tag = MenuController.TEXT_VIEW_TAG
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: menu.size.width, height: 0))
        let imageInfo = descriptor?.imageInfo
        textView.descriptionLabel.stringValue = imageInfo?.title ?? ""
        textView.copyrightLabel.stringValue = imageInfo?.copyright ?? ""
        textView.button.action = #selector(imageInfoAction(_:))
        textView.button.target = self
        textView.button.toolTip = "Show image details and actions"
        textItem.view = textView
        
        if let oldTextItem = menu.item(withTag: MenuController.TEXT_VIEW_TAG) {
            menu.removeItem(oldTextItem)
        }
        let imageView = menu.item(withTag: MenuController.IMAGE_VIEW_TAG)!
        let textViewIndex = menu.index(of: imageView) + 1
        menu.insertItem(textItem, at: textViewIndex)
        
        imageSelectorView.leftButton.isEnabled = descriptors.indices.contains(newSelectedDescriptorIndex - 1)
        imageSelectorView.rightButton.isEnabled = descriptors.indices.contains(newSelectedDescriptorIndex + 1)
    }
    
    private func imageActionsMenu(for descriptor: ImageDescriptor) -> NSMenu {
        let menu = NSMenu(title: "Wallpaper Details")
        let info = descriptor.imageInfo
        addImageDetail(title: "Title: \(info.title)", fullText: info.title, to: menu)
        addImageDetail(title: "Date: \(info.date)", fullText: info.date, to: menu)
        addImageDetail(title: "Region: \(info.region)", fullText: info.region, to: menu)
        if info.copyright.isEmpty == false {
            addImageDetail(
                title: "Copyright: \(info.copyright)",
                fullText: info.copyright,
                to: menu
            )
        }

        menu.addItem(.separator())
        addImageAction(title: "Open Source on Bing", selector: #selector(openImageSource(_:)), to: menu)
        addImageAction(title: "Show in Finder", selector: #selector(revealImageInFinder(_:)), to: menu)
        addImageAction(title: "Save a Copy…", selector: #selector(saveImageCopy(_:)), to: menu)
        return menu
    }

    private func addImageDetail(title: String, fullText: String, to menu: NSMenu) {
        let displayTitle = title.count > 100 ? String(title.prefix(97)) + "…" : title
        let item = NSMenuItem(title: displayTitle, action: nil, keyEquivalent: "")
        item.toolTip = fullText
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addImageAction(title: String, selector: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @MainActor
    private func updateStatusMenu() {
        guard let menu,
              let updateManager,
              let statusItem = menu.item(withTag: MenuController.UPDATE_STATUS_TAG) else {
            return
        }

        let status = updateManager.status
        statusItem.title = status.menuTitle
        statusItem.image = updateStatusImage(for: status.phase)

        let detailsMenu = NSMenu()
        addStatusDetail(
            title: "Last successful update: \(formattedDate(status.lastSuccessAt))",
            to: detailsMenu
        )
        if let lastAttemptAt = status.lastAttemptAt {
            addStatusDetail(title: "Last attempt: \(formattedDate(lastAttemptAt))", to: detailsMenu)
        }
        if let nextAttemptAt = status.nextAttemptAt {
            let label = status.phase == .retrying ? "Next retry" : "Next update"
            addStatusDetail(title: "\(label): \(formattedDate(nextAttemptAt))", to: detailsMenu)
        }
        if let failure = status.failure {
            detailsMenu.addItem(.separator())
            addStatusDetail(title: "Failed step: \(failure.stage.title)", to: detailsMenu)
            let message = failure.message.count > 120
                ? String(failure.message.prefix(117)) + "…"
                : failure.message
            let errorItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            errorItem.toolTip = failure.message
            errorItem.isEnabled = false
            detailsMenu.addItem(errorItem)
        }
        statusItem.submenu = detailsMenu

        if let refreshItem = menu.item(withTag: MenuController.REFRESH_IMAGES_TAG) {
            refreshItem.title = status.phase == .retrying || status.phase == .failed
                ? "Retry Now"
                : "Refresh Images"
            refreshItem.isEnabled = status.phase != .updating
        }
    }

    private func addStatusDetail(title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    private func updateStatusImage(for phase: WallpaperUpdatePhase) -> NSImage? {
        let symbolName: String
        switch phase {
        case .idle, .succeeded:
            symbolName = "checkmark.circle"
        case .updating:
            symbolName = "arrow.triangle.2.circlepath"
        case .retrying, .failed:
            symbolName = "exclamationmark.triangle"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Wallpaper update status")
    }
    
    @MainActor
    private func showNewestImage() {
        self.descriptors = Database.instance.allImageDescriptors(marketCode: settings.bingMarketCode)
            .filter { $0.image.isOnDisk() }
        guard descriptors.isEmpty == false else {
            selectedDescriptorIndex = 0
            imageSelectorView?.imageView.image = nil
            return
        }
        selectedDescriptorIndex = descriptors.count - 1
        updateSelectedImage(newSelectedDescriptorIndex: selectedDescriptorIndex)
    }
}

// MARK: - Delegates

extension MenuController: UpdateManagerDelegate {
    func downloadedNewImage() {
        showNewestImage()
    }

    func updateStatusDidChange(_ status: WallpaperUpdateStatus) {
        updateStatusMenu()
    }
}

extension MenuController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateImageSelectorView(newSelectedDescriptorIndex: selectedDescriptorIndex)
        updateStatusMenu()
    }
}

extension MenuController: SettingsVcDelegate {
    func bingMarketDidChange() {
        showNewestImage()
    }

    func wallpaperDisplaySelectionDidChange() {
        WallpaperManager.shared.refreshWallpaper()
    }

    func wallpaperStorageDidChange() {
        showNewestImage()
    }

    func showMenuBarIcon() {
        setup()
    }
    
    func hideMenuBarIcon() {
        guard let statusItem = statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.menu?.removeAllItems()
        self.menu = nil
        self.statusItem = nil
    }
}
