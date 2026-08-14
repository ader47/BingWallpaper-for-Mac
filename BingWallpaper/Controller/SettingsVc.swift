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
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLaunchAtLoginCheckbox()
        refreshWallpaperDisplaySelector()
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
    
    @IBAction func keepImagesSliderAction(_ sender: NSSlider) {
        settings.keepImageDuration = sender.integerValue
        setKeepImagesText()
    }
    
    @IBAction func resetDatabaseButtonAction(_ sender: NSButton) {
        logger.info("Resetting Database...")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "YYYYMMdd"
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
