import Cocoa
import OSLog
import ServiceManagement

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Settings.rawValue
)

protocol SettingsVcDelegate: AnyObject {
    @MainActor
    func bingMarketDidChange()
    @MainActor
    func wallpaperDisplaySelectionDidChange()
    @MainActor
    func wallpaperStorageDidChange()
    @MainActor
    func showMenuBarIcon()
    @MainActor
    func hideMenuBarIcon()
}

class SettingsVc: NSViewController {
    @IBOutlet var launchAtLoginCheckBox: NSButton!
    @IBOutlet weak var hideMenuBarIconCheckBox: NSButton!
    @IBOutlet var imagePathButton: NSButton!
    @IBOutlet weak var keepImagesSlider: NSSlider!
    @IBOutlet weak var keepImagesTextField: NSTextField!

    private let bingMarketLabel = NSTextField(labelWithString: "Bing region:")
    private let bingMarketPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wallpaperDisplayLabel = NSTextField(labelWithString: "Apply wallpaper to:")
    private let wallpaperDisplayPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayProfilesLabel = NSTextField(labelWithString: "Per-display profiles:")
    private let displayProfilesButton = NSButton(title: "Configure…", target: nil, action: nil)
    
    private let settings = Settings()
    weak var delegate: SettingsVcDelegate?
    weak var updateManager: UpdateManager?
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        refreshLaunchAtLoginCheckbox()
        hideMenuBarIconCheckBox.state = settings.hideMenuBarIcon ? .on : .off
        imagePathButton.title = settings.imageDownloadPath.path
        imagePathButton.toolTip = imagePathButton.title
        keepImagesSlider.integerValue = settings.keepImageDuration
        setKeepImagesText()
        setupBingMarketSelector()
        setupWallpaperDisplaySelector()
        setupDisplayProfilesButton()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLaunchAtLoginCheckbox()
        refreshWallpaperDisplaySelector()
        refreshDisplayProfilesButton()
    }

    // MARK: - Actions

    @IBAction func launchAtLoginAction(_ sender: NSButton) {
        let newState = sender.state == .on
        do {
            try settings.setLaunchAtLogin(newState)
        } catch {
            logger.error("Failed to toggle launch-at-login: \(String(describing: error), privacy: .public)")
            refreshLaunchAtLoginCheckbox()
            presentLaunchAtLoginError(error)
            return
        }

        // Sync the checkbox to the real status 
        refreshLaunchAtLoginCheckbox()

        if newState, settings.launchAtLoginRequiresApproval {
            promptToApproveLoginItem()
        }
    }
    
    @IBAction func hideMenuBarIconCheckBoxAction(_ sender: NSButton) {
        let newState = sender.state == .on
        settings.hideMenuBarIcon = newState
        if newState == true {
            delegate?.hideMenuBarIcon()
        } else {
            delegate?.showMenuBarIcon()
        }
    }
    
    @IBAction func imagePathButtonAction(_ sender: NSButton) {
        let dialog = NSOpenPanel()
        dialog.showsResizeIndicator = true
        dialog.showsHiddenFiles = false
        dialog.allowsMultipleSelection = false
        dialog.canChooseDirectories = true
        
        if dialog.runModal() == NSApplication.ModalResponse.OK {
            guard let result = dialog.url else { return }
            do {
                try settings.setImageDownloadPath(result)
                imagePathButton.title = result.path
                imagePathButton.toolTip = result.path
                delegate?.wallpaperStorageDidChange()
                updateManager?.update()
            } catch {
                logger.error("Failed to save image directory permission: \(error.localizedDescription, privacy: .public)")
                presentImagePathError(error)
            }
        }
    }

    @objc private func bingMarketAction(_ sender: NSPopUpButton) {
        let oldMarketCode = settings.bingMarketCode
        let newMarketCode = sender.selectedItem?.representedObject as? String
        settings.bingMarketCode = newMarketCode

        guard oldMarketCode != settings.bingMarketCode else { return }
        delegate?.bingMarketDidChange()
        updateManager?.update()
    }

    @objc private func wallpaperDisplayAction(_ sender: NSPopUpButton) {
        let oldMode = settings.wallpaperDisplayMode
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let newMode = WallpaperDisplayMode(rawValue: rawValue) else {
            refreshWallpaperDisplaySelector()
            return
        }

        if newMode == .selected, !presentWallpaperDisplaySelection() {
            selectWallpaperDisplayMode(oldMode)
            return
        }

        settings.wallpaperDisplayMode = newMode
        refreshWallpaperDisplaySelector()
        guard oldMode != newMode || newMode == .selected else { return }
        delegate?.wallpaperDisplaySelectionDidChange()
    }

    @objc private func displayProfilesAction(_ sender: NSButton) {
        presentDisplayProfileConfiguration()
    }
    
    @IBAction func keepImagesSliderAction(_ sender: NSSlider) {
        settings.keepImageDuration = sender.integerValue
        setKeepImagesText()
    }
    
    @IBAction func resetDatabaseButtonAction(_ sender: NSButton) {
        logger.info("Resetting Database...")
        settings.favoriteWallpaperIDs = []
        settings.pinnedWallpaperID = nil
        settings.wallpaperDisplayProfiles = settings.wallpaperDisplayProfiles.mapValues { profile in
            var profile = profile
            profile.pinnedWallpaperID = nil
            return profile
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let oldestDateStringToKeep = dateFormatter.string(from: Date())
        
        do {
           try Database.instance.deleteImageDescriptors(olderThan: oldestDateStringToKeep)
        } catch let error {
            logger.error("Failed resetting Database: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Failed to reset Database"
            alert.informativeText = error.localizedDescription
            let updateButton = alert.addButton(withTitle: "Ok")
            alert.alertStyle = .informational
            alert.window.defaultButtonCell = updateButton.cell as? NSButtonCell
            alert.runModal()
        }
        
        updateManager?.update()
    }
    
    // MARK: - Private

    private func refreshLaunchAtLoginCheckbox() {
        launchAtLoginCheckBox.state = settings.launchAtLogin ? .on : .off
    }

    private func setupBingMarketSelector() {
        let options = BingMarketOption.all
        bingMarketPopUpButton.removeAllItems()
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.code
            bingMarketPopUpButton.menu?.addItem(item)
        }

        if let selectedIndex = options.firstIndex(where: { $0.code == settings.bingMarketCode }) {
            bingMarketPopUpButton.selectItem(at: selectedIndex)
        }
        bingMarketPopUpButton.target = self
        bingMarketPopUpButton.action = #selector(bingMarketAction(_:))

        bingMarketLabel.translatesAutoresizingMaskIntoConstraints = false
        bingMarketPopUpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bingMarketLabel)
        view.addSubview(bingMarketPopUpButton)

        // Insert the market row between the menu-bar preference and image path.
        if let oldImageTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === imagePathButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === hideMenuBarIconCheckBox &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([oldImageTopConstraint])
        }

        NSLayoutConstraint.activate([
            bingMarketPopUpButton.topAnchor.constraint(equalTo: hideMenuBarIconCheckBox.bottomAnchor, constant: 12),
            bingMarketPopUpButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            bingMarketPopUpButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            imagePathButton.topAnchor.constraint(equalTo: bingMarketPopUpButton.bottomAnchor, constant: 12),
            bingMarketLabel.trailingAnchor.constraint(equalTo: bingMarketPopUpButton.leadingAnchor, constant: -8),
            bingMarketLabel.centerYAnchor.constraint(equalTo: bingMarketPopUpButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: view.frame.width, height: view.frame.height + 40)
    }

    private func setupWallpaperDisplaySelector() {
        wallpaperDisplayLabel.translatesAutoresizingMaskIntoConstraints = false
        wallpaperDisplayPopUpButton.translatesAutoresizingMaskIntoConstraints = false
        wallpaperDisplayPopUpButton.target = self
        wallpaperDisplayPopUpButton.action = #selector(wallpaperDisplayAction(_:))
        view.addSubview(wallpaperDisplayLabel)
        view.addSubview(wallpaperDisplayPopUpButton)
        refreshWallpaperDisplaySelector()

        if let imageTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === imagePathButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === bingMarketPopUpButton &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([imageTopConstraint])
        }

        NSLayoutConstraint.activate([
            wallpaperDisplayPopUpButton.topAnchor.constraint(equalTo: bingMarketPopUpButton.bottomAnchor, constant: 12),
            wallpaperDisplayPopUpButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            wallpaperDisplayPopUpButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            imagePathButton.topAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.bottomAnchor, constant: 12),
            wallpaperDisplayLabel.trailingAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.leadingAnchor, constant: -8),
            wallpaperDisplayLabel.centerYAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: preferredContentSize.width, height: preferredContentSize.height + 40)
    }

    private func setupDisplayProfilesButton() {
        displayProfilesLabel.translatesAutoresizingMaskIntoConstraints = false
        displayProfilesButton.translatesAutoresizingMaskIntoConstraints = false
        displayProfilesButton.target = self
        displayProfilesButton.action = #selector(displayProfilesAction(_:))
        displayProfilesButton.alignment = .left
        view.addSubview(displayProfilesLabel)
        view.addSubview(displayProfilesButton)
        refreshDisplayProfilesButton()

        if let imageTopConstraint = view.constraints.first(where: {
            ($0.firstItem as? NSView) === imagePathButton &&
            $0.firstAttribute == .top &&
            ($0.secondItem as? NSView) === wallpaperDisplayPopUpButton &&
            $0.secondAttribute == .bottom
        }) {
            NSLayoutConstraint.deactivate([imageTopConstraint])
        }

        NSLayoutConstraint.activate([
            displayProfilesButton.topAnchor.constraint(equalTo: wallpaperDisplayPopUpButton.bottomAnchor, constant: 12),
            displayProfilesButton.leadingAnchor.constraint(equalTo: imagePathButton.leadingAnchor),
            displayProfilesButton.widthAnchor.constraint(equalTo: imagePathButton.widthAnchor),
            imagePathButton.topAnchor.constraint(equalTo: displayProfilesButton.bottomAnchor, constant: 12),
            displayProfilesLabel.trailingAnchor.constraint(equalTo: displayProfilesButton.leadingAnchor, constant: -8),
            displayProfilesLabel.centerYAnchor.constraint(equalTo: displayProfilesButton.centerYAnchor)
        ])

        preferredContentSize = NSSize(width: preferredContentSize.width, height: preferredContentSize.height + 40)
    }

    private func refreshDisplayProfilesButton() {
        let count = settings.wallpaperDisplayProfiles.count
        displayProfilesButton.title = count == 0
            ? "Configure…"
            : "Configure (\(count))…"
    }

    private func refreshWallpaperDisplaySelector() {
        let selectedCount = settings.selectedWallpaperDisplayIDs.count
        wallpaperDisplayPopUpButton.removeAllItems()
        for mode in WallpaperDisplayMode.allCases {
            let title: String
            if mode == .selected, selectedCount > 0 {
                title = "Selected Displays (\(selectedCount))…"
            } else {
                title = mode.title
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            wallpaperDisplayPopUpButton.menu?.addItem(item)
        }
        selectWallpaperDisplayMode(settings.wallpaperDisplayMode)
    }

    private func selectWallpaperDisplayMode(_ mode: WallpaperDisplayMode) {
        guard let item = wallpaperDisplayPopUpButton.itemArray.first(where: {
            ($0.representedObject as? String) == mode.rawValue
        }) else { return }
        wallpaperDisplayPopUpButton.select(item)
    }

    private func presentWallpaperDisplaySelection() -> Bool {
        let displays = WallpaperManager.connectedDisplays()
        guard !displays.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No displays are available"
            alert.informativeText = "Connect a display and try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }

        let previouslySelected = settings.selectedWallpaperDisplayIDs
        let initiallySelected: Set<String>
        if previouslySelected.isEmpty {
            initiallySelected = Set(displays.filter(\.isMain).map(\.identifier))
        } else {
            initiallySelected = previouslySelected
        }

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        var checkBoxes = [NSButton]()
        for display in displays {
            let checkBox = NSButton(checkboxWithTitle: display.title, target: nil, action: nil)
            checkBox.state = initiallySelected.contains(display.identifier) ? .on : .off
            checkBoxes.append(checkBox)
            stackView.addArrangedSubview(checkBox)
        }
        stackView.frame = NSRect(x: 0, y: 0, width: 420, height: max(28, CGFloat(displays.count) * 26))

        let alert = NSAlert()
        alert.messageText = "Choose displays"
        alert.informativeText = "BingWallpaper will update only the selected displays. Disconnected displays remain selected and will resume when reconnected."
        alert.alertStyle = .informational
        alert.accessoryView = stackView
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let connectedIDs = Set(displays.map(\.identifier))
        let disconnectedSelections = previouslySelected.subtracting(connectedIDs)
        let checkedIDs = Set(zip(displays, checkBoxes).compactMap { display, checkBox in
            checkBox.state == .on ? display.identifier : nil
        })
        let newSelection = disconnectedSelections.union(checkedIDs)
        guard !newSelection.isEmpty else {
            let emptyAlert = NSAlert()
            emptyAlert.messageText = "Select at least one display"
            emptyAlert.alertStyle = .warning
            emptyAlert.addButton(withTitle: "OK")
            emptyAlert.runModal()
            return false
        }

        settings.selectedWallpaperDisplayIDs = newSelection
        return true
    }

    private func presentDisplayProfileConfiguration() {
        let displays = WallpaperManager.connectedDisplays()
        guard displays.isEmpty == false else {
            let alert = NSAlert()
            alert.messageText = "No displays are available"
            alert.informativeText = "Connect a display and try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        var controls = [(WallpaperDisplayInfo, NSPopUpButton, NSPopUpButton)]()
        var rows = [[NSView]]()
        rows.append([
            profileHeader("Display"),
            profileHeader("Bing Region"),
            profileHeader("Update Behavior")
        ])
        let profiles = settings.wallpaperDisplayProfiles
        for display in displays {
            let profile = profiles[display.identifier] ?? WallpaperDisplayProfile()
            let marketSelector = displayMarketSelector(for: profile)
            let pinSelector = displayPinSelector(for: profile)
            let displayLabel = NSTextField(labelWithString: display.title)
            displayLabel.lineBreakMode = .byTruncatingTail
            displayLabel.toolTip = display.title
            rows.append([displayLabel, marketSelector, pinSelector])
            controls.append((display, marketSelector, pinSelector))
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).width = 230
        grid.column(at: 1).width = 250
        grid.column(at: 2).width = 170
        grid.frame = NSRect(
            x: 0,
            y: 0,
            width: 670,
            height: CGFloat(rows.count) * 34
        )

        let accessoryView: NSView
        if rows.count > 6 {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 670, height: 220))
            scrollView.documentView = grid
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            accessoryView = scrollView
        } else {
            accessoryView = grid
        }

        let alert = NSAlert()
        alert.messageText = "Configure Displays"
        alert.informativeText = "Each display can inherit the global settings or use its own Bing region and update behavior. Disconnected display profiles remain saved."
        alert.alertStyle = .informational
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var updatedProfiles = profiles
        let descriptors = Database.instance.allImageDescriptors()
        for (display, marketSelector, pinSelector) in controls {
            var profile = updatedProfiles[display.identifier] ?? WallpaperDisplayProfile()
            applyMarketSelection(marketSelector, to: &profile)
            let oldPinMode = profile.pinMode
            profile.pinMode = WallpaperDisplayPinMode(
                rawValue: pinSelector.selectedItem?.representedObject as? String ?? ""
            ) ?? .inherit
            if profile.pinMode != .pinned {
                profile.pinnedWallpaperID = nil
            } else {
                let effectiveMarketCode = profile.effectiveMarketCode(
                    globalMarketCode: settings.bingMarketCode
                )
                let oldPinnedDescriptor = profile.pinnedWallpaperID.flatMap { pinnedID in
                    descriptors.first { $0.wallpaperIdentifier == pinnedID }
                }
                if oldPinMode != .pinned || oldPinnedDescriptor?.marketCode != effectiveMarketCode {
                    let currentWallpaperID = WallpaperManager.currentWallpaperIdentifier(
                        forDisplayIdentifier: display.identifier
                    )
                    let currentDescriptor = currentWallpaperID.flatMap { wallpaperID in
                        descriptors.first { $0.wallpaperIdentifier == wallpaperID }
                    }
                    profile.pinnedWallpaperID = currentDescriptor?.marketCode == effectiveMarketCode
                        ? currentDescriptor?.wallpaperIdentifier
                        : descriptors
                            .filter {
                                $0.marketCode == effectiveMarketCode && $0.image.isOnDisk()
                            }
                            .max()?
                            .wallpaperIdentifier
                }
            }

            if profile.isDefault {
                updatedProfiles.removeValue(forKey: display.identifier)
            } else {
                updatedProfiles[display.identifier] = profile
            }
        }

        settings.wallpaperDisplayProfiles = updatedProfiles
        refreshDisplayProfilesButton()
        delegate?.wallpaperDisplaySelectionDidChange()
        updateManager?.update()
    }

    private func profileHeader(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private func displayMarketSelector(for profile: WallpaperDisplayProfile) -> NSPopUpButton {
        let selector = NSPopUpButton(frame: .zero, pullsDown: false)
        let globalTitle = BingMarketOption.all.first(where: {
            $0.code == settings.bingMarketCode
        })?.title ?? BingMarketOption.automatic.title
        addProfileOption(title: "Inherit Global — \(globalTitle)", value: "inherit", to: selector)
        addProfileOption(title: BingMarketOption.automatic.title, value: "automatic", to: selector)
        for option in BingMarketOption.all where option.code != nil {
            addProfileOption(title: option.title, value: option.code!, to: selector)
        }

        let selectedValue: String
        switch profile.marketMode {
        case .inherit:
            selectedValue = "inherit"
        case .automatic:
            selectedValue = "automatic"
        case .explicit:
            selectedValue = profile.marketCode ?? "inherit"
        }
        selector.select(selector.itemArray.first(where: {
            ($0.representedObject as? String) == selectedValue
        }))
        return selector
    }

    private func displayPinSelector(for profile: WallpaperDisplayProfile) -> NSPopUpButton {
        let selector = NSPopUpButton(frame: .zero, pullsDown: false)
        addProfileOption(title: "Inherit Global", value: WallpaperDisplayPinMode.inherit.rawValue, to: selector)
        addProfileOption(title: "Follow Latest", value: WallpaperDisplayPinMode.followLatest.rawValue, to: selector)
        addProfileOption(title: "Pin Current", value: WallpaperDisplayPinMode.pinned.rawValue, to: selector)
        selector.select(selector.itemArray.first(where: {
            ($0.representedObject as? String) == profile.pinMode.rawValue
        }))
        return selector
    }

    private func addProfileOption(title: String, value: String, to selector: NSPopUpButton) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = value
        selector.menu?.addItem(item)
    }

    private func applyMarketSelection(
        _ selector: NSPopUpButton,
        to profile: inout WallpaperDisplayProfile
    ) {
        let value = selector.selectedItem?.representedObject as? String ?? "inherit"
        switch value {
        case "inherit":
            profile.marketMode = .inherit
            profile.marketCode = nil
        case "automatic":
            profile.marketMode = .automatic
            profile.marketCode = nil
        default:
            profile.marketMode = .explicit
            profile.marketCode = BingMarketOption.supportedCodes.contains(value) ? value : nil
        }
    }

    private func promptToApproveLoginItem() {
        let alert = NSAlert()
        alert.messageText = "Approve BingWallpaper in Login Items"
        alert.informativeText = "BingWallpaper has been added to your Login Items but macOS needs your approval before it can launch at login. Open System Settings to confirm it."
        alert.alertStyle = .informational
        let openButton = alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Later")
        alert.window.defaultButtonCell = openButton.cell as? NSButtonCell

        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func presentLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't update Launch at Login"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ok")
        alert.runModal()
    }

    private func presentImagePathError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't use the selected image location"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ok")
        alert.runModal()
    }

    private func setKeepImagesText() {
        guard let keepImageDuration = KeepImageDuration(rawValue: settings.keepImageDuration) else { return }
        
        switch keepImageDuration {
        case .five, .ten, .fifty, .onehundred:
            keepImagesTextField.stringValue = "Keep last \(keepImageDuration.text) images:"
        case .infinite:
            keepImagesTextField.stringValue = "Keep all images forever:"
        }
    }
}

enum KeepImageDuration: Int {
    case five
    case ten
    case fifty
    case onehundred
    case infinite
    
    var text: String {
        switch self {
        case .five:
            return "5"
        case .ten:
            return "10"
        case .fifty:
            return "50"
        case .onehundred:
            return "100"
        case .infinite:
            return "∞"
        }
    }
}
