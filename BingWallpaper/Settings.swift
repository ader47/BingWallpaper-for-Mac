
import Foundation
import ServiceManagement
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Settings.rawValue
)

struct BingMarketOption: Equatable {
    let code: String?
    let title: String

    static let automatic = BingMarketOption(
        code: nil,
        title: "Automatic (Network Location)"
    )

    // Bing's documented `mkt` values. A market is a language and a
    // country/region, so a country can appear more than once.
    static let supportedCodes = [
        "es-AR", "en-AU", "de-AT", "nl-BE", "fr-BE", "pt-BR",
        "en-CA", "fr-CA", "es-CL", "da-DK", "fi-FI", "fr-FR",
        "de-DE", "zh-HK", "en-IN", "en-ID", "it-IT", "ja-JP",
        "ko-KR", "en-MY", "es-MX", "nl-NL", "en-NZ", "no-NO",
        "zh-CN", "pl-PL", "en-PH", "ru-RU", "en-ZA", "es-ES",
        "sv-SE", "fr-CH", "de-CH", "zh-TW", "tr-TR", "en-GB",
        "en-US", "es-US"
    ]

    static var all: [BingMarketOption] {
        let localizedMarkets = supportedCodes
            .map { code in
                let localizedName = Locale.current.localizedString(forIdentifier: code) ?? code
                return BingMarketOption(code: code, title: "\(localizedName) (\(code))")
            }
            .sorted { (lhs: BingMarketOption, rhs: BingMarketOption) in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        return [automatic] + localizedMarkets
    }
}

public class Settings {
    private let defaults = UserDefaults.standard

    public init() {
        migrateLegacyLoginItemIfNeeded()
    }

    /// `true` when the user's intent is "launch at login enabled".
    ///
    /// On macOS 15+/26 the system frequently keeps a freshly registered login
    /// item in `.requiresApproval` until the user confirms it in
    /// System Settings → General → Login Items. We treat that as "on" so the
    /// checkbox doesn't snap back to off the instant the user toggles it.
    var launchAtLogin: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    /// `true` when the login item is registered but waiting for the user to
    /// approve it in System Settings. Callers should route the user there.
    var launchAtLoginRequiresApproval: Bool {
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// Register or unregister the main app as a login item. Throws on failure
    /// so the caller can surface the error to the user instead of swallowing
    /// it.
    func setLaunchAtLogin(_ newValue: Bool) throws {
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let actionString = newValue ? "register" : "unregister"
            logger.error("Failed to \(actionString, privacy: .public) login item with error: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func migrateLegacyLoginItemIfNeeded() {
        guard defaults.object(forKey: Settings.SM_LOGIN_ENABLED_LEGACY) != nil else { return }
        let wasEnabled = defaults.bool(forKey: Settings.SM_LOGIN_ENABLED_LEGACY)
        defaults.removeObject(forKey: Settings.SM_LOGIN_ENABLED_LEGACY)
        if wasEnabled, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
    
    var hideMenuBarIcon: Bool {
        get {
            return defaults.bool(forKey: Settings.HIDE_MENU_BAR_ICON)
        }
        set {
            defaults.set(newValue, forKey: Settings.HIDE_MENU_BAR_ICON)
        }
    }
    
    var imageDownloadPath: URL {
        get {
            return defaults.url(forKey: Settings.IMAGE_DOWNLOAD_PATH) ?? FileHandler.defaultBingWallpaperDirectory()
        }
        set {
            defaults.set(newValue, forKey: Settings.IMAGE_DOWNLOAD_PATH)
        }
    }

    /// The explicit Bing market selected by the user, or `nil` when Bing
    /// should infer it from the network location.
    var bingMarketCode: String? {
        get {
            guard let code = defaults.string(forKey: Settings.BING_MARKET_CODE),
                  BingMarketOption.supportedCodes.contains(code) else {
                return nil
            }
            return code
        }
        set {
            if let newValue, BingMarketOption.supportedCodes.contains(newValue) {
                defaults.set(newValue, forKey: Settings.BING_MARKET_CODE)
            } else {
                defaults.removeObject(forKey: Settings.BING_MARKET_CODE)
            }
        }
    }
    
    public var lastUpdate: Date {
        get {
            return defaults.object(forKey: Settings.LAST_UPDATE) as? Date ?? Date.distantPast
        }
        set {
            defaults.set(newValue, forKey: Settings.LAST_UPDATE)
        }
    }
    
    var keepImageDuration: Int {
        get {
            return defaults.object(forKey: Settings.KEEP_IMAGE_DURATION) as? Int ?? KeepImageDuration.fifty.rawValue
        }
        set {
            defaults.set(newValue, forKey: Settings.KEEP_IMAGE_DURATION)
        }
    }
    
    private func keepImageTimeInterval() -> TimeInterval? {
        let durationInDays: Double?
        
        switch keepImageDuration {
        case KeepImageDuration.five.rawValue:
            durationInDays = 5
        case KeepImageDuration.ten.rawValue:
            durationInDays = 10
        case KeepImageDuration.fifty.rawValue:
            durationInDays = 50
        case KeepImageDuration.onehundred.rawValue:
            durationInDays = 100
        case KeepImageDuration.infinite.rawValue:
            durationInDays = nil
        default:
            durationInDays = 50
        }
        
        guard let durationInDays = durationInDays else {
            return nil
        }
        
        return durationInDays * 3600.0 * 24.0
    }
    
    func oldestDateToKeep() -> Date? {
        guard let keepImageTimeInterval = keepImageTimeInterval() else {
            return nil
        }
        return Date().addingTimeInterval(-keepImageTimeInterval)
    }
    
    func oldestDateStringToKeep() -> String? {
        guard let oldestDateToKeep = oldestDateToKeep() else {
            return nil
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        return dateFormatter.string(from: oldestDateToKeep)
    }
    
    private static let SM_LOGIN_ENABLED_LEGACY = "SM_LOGIN_ENABLED"
    private static let HIDE_MENU_BAR_ICON = "HIDE_MENU_BAR_ICON"
    private static let IMAGE_DOWNLOAD_PATH = "IMAGE_DOWNLOAD_PATH"
    private static let BING_MARKET_CODE = "BING_MARKET_CODE"
    private static let LAST_UPDATE = "LAST_UPDATE"
    private static let KEEP_IMAGE_DURATION = "KEEP_IMAGE_DURATION"
}
