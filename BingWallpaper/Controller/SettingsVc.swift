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
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLaunchAtLoginCheckbox()
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
            settings.imageDownloadPath = result
            imagePathButton.title = result.path
            imagePathButton.toolTip = result.path
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
