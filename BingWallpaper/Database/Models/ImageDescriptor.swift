import AppKit
import CoreData
import Foundation

struct WallpaperImageInfo: Equatable {
    let title: String
    let copyright: String
    let date: String
    let region: String

    init(
        description: String,
        startDate: String,
        marketCode: String?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        let components = Self.descriptionComponents(from: description)
        title = components.title
        copyright = components.copyright
        date = Self.formattedDate(
            from: startDate,
            locale: locale,
            timeZone: timeZone
        )
        region = Self.regionTitle(for: marketCode, locale: locale)
    }

    private static func descriptionComponents(from description: String) -> (title: String, copyright: String) {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDescription.hasSuffix(")"),
              let separatorRange = trimmedDescription.range(of: " (", options: .backwards) else {
            return (trimmedDescription, "")
        }

        let title = trimmedDescription[..<separatorRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let copyrightStart = separatorRange.upperBound
        let copyrightEnd = trimmedDescription.index(before: trimmedDescription.endIndex)
        let copyright = trimmedDescription[copyrightStart..<copyrightEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard copyright.isEmpty == false else { return (trimmedDescription, "") }
        return (title, copyright)
    }

    private static func formattedDate(
        from startDate: String,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyyMMdd"
        guard let parsedDate = parser.date(from: startDate) else { return startDate }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: parsedDate)
    }

    private static func regionTitle(for marketCode: String?, locale: Locale) -> String {
        guard let marketCode else { return BingMarketOption.automatic.title }
        let localizedName = locale.localizedString(forIdentifier: marketCode) ?? marketCode
        return "\(localizedName) (\(marketCode))"
    }
}

public final class ImageDescriptor: NSManagedObject {
    enum ValidationError: LocalizedError, Equatable {
        case invalidStartDate(String)
        case invalidEndDate(String)
        case invalidImageURL(String)
        case invalidCopyrightURL(String)
        case missingEntity

        var errorDescription: String? {
            switch self {
            case .invalidStartDate(let value):
                return "Invalid Bing start date: \(value)"
            case .invalidEndDate(let value):
                return "Invalid Bing end date: \(value)"
            case .invalidImageURL(let value):
                return "Invalid Bing image URL: \(value)"
            case .invalidCopyrightURL(let value):
                return "Invalid Bing copyright URL: \(value)"
            case .missingEntity:
                return "The wallpaper database model is missing ImageDescriptor"
            }
        }
    }

    struct ValidatedMetadata {
        let startDate: String
        let endDate: String
        let imageURL: URL
        let copyrightURL: URL
    }

    @NSManaged var startDate: String
    @NSManaged var endDate: String
    @NSManaged var imageUrl: URL
    @NSManaged var descriptionString: String
    @NSManaged var copyrightUrl: URL
    @NSManaged var marketCode: String?
    @NSManaged var requiresImageDownload: Bool
    lazy var image: Image = {
        return Image(descriptor: self)
    }()

    var imageInfo: WallpaperImageInfo {
        return WallpaperImageInfo(
            description: descriptionString,
            startDate: startDate,
            marketCode: marketCode
        )
    }

    var wallpaperIdentifier: String {
        return Self.wallpaperIdentifier(startDate: startDate, marketCode: marketCode)
    }

    static func wallpaperIdentifier(startDate: String, marketCode: String?) -> String {
        return "\(marketCode ?? "automatic"):\(startDate)"
    }
    
    static func == (lhs: ImageDescriptor, rhs: ImageDescriptor) -> Bool {
        return lhs.startDate == rhs.startDate && lhs.marketCode == rhs.marketCode
    }
    
    static func instantiate(
        from entry: DownloadManager.ImageEntry,
        marketCode: String?,
        in managedContext: NSManagedObjectContext
    ) throws -> ImageDescriptor {
        let metadata = try validatedMetadata(from: entry)
        guard let entity = NSEntityDescription.entity(
            forEntityName: "ImageDescriptor",
            in: managedContext
        ) else {
            throw ValidationError.missingEntity
        }
        let imageDescriptor = ImageDescriptor(entity: entity, insertInto: managedContext)
        imageDescriptor.startDate = metadata.startDate
        imageDescriptor.endDate = metadata.endDate
        imageDescriptor.imageUrl = metadata.imageURL
        imageDescriptor.descriptionString = entry.copyright
        imageDescriptor.copyrightUrl = metadata.copyrightURL
        imageDescriptor.marketCode = marketCode
        imageDescriptor.requiresImageDownload = true
        return imageDescriptor
    }

    @discardableResult
    func update(from entry: DownloadManager.ImageEntry) throws -> Bool {
        let metadata = try Self.validatedMetadata(from: entry)
        let imageChanged = Self.metadataRequiresImageRefresh(
            currentImageURL: imageUrl,
            newImageURL: metadata.imageURL
        )
        startDate = metadata.startDate
        endDate = metadata.endDate
        imageUrl = metadata.imageURL
        descriptionString = entry.copyright
        copyrightUrl = metadata.copyrightURL
        if imageChanged {
            requiresImageDownload = true
        }
        return imageChanged
    }

    static func metadataRequiresImageRefresh(currentImageURL: URL, newImageURL: URL) -> Bool {
        return currentImageURL.absoluteURL != newImageURL.absoluteURL
    }

    static func validatedMetadata(from entry: DownloadManager.ImageEntry) throws -> ValidatedMetadata {
        guard isValidBingDate(entry.startdate) else {
            throw ValidationError.invalidStartDate(entry.startdate)
        }
        guard isValidBingDate(entry.enddate) else {
            throw ValidationError.invalidEndDate(entry.enddate)
        }

        let bingBaseURL = URL(string: "https://www.bing.com")!
        let imagePath = entry.url.replacingOccurrences(of: "1920x1080", with: "UHD")
        guard let imageURL = URL(string: imagePath, relativeTo: bingBaseURL)?.absoluteURL,
              isTrustedBingURL(imageURL) else {
            throw ValidationError.invalidImageURL(entry.url)
        }
        guard let copyrightURL = URL(string: entry.copyrightlink, relativeTo: bingBaseURL)?.absoluteURL,
              isTrustedBingURL(copyrightURL) else {
            throw ValidationError.invalidCopyrightURL(entry.copyrightlink)
        }

        return ValidatedMetadata(
            startDate: entry.startdate,
            endDate: entry.enddate,
            imageURL: imageURL,
            copyrightURL: copyrightURL
        )
    }

    static func isValidBingDate(_ value: String) -> Bool {
        guard value.utf8.count == 8,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            return false
        }

        guard let year = Int(value.prefix(4)) else { return false }
        let monthStart = value.index(value.startIndex, offsetBy: 4)
        let dayStart = value.index(value.startIndex, offsetBy: 6)
        guard let month = Int(value[monthStart..<dayStart]),
              let day = Int(value[dayStart...]) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }

    private static func isTrustedBingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "bing.com" || host.hasSuffix(".bing.com")
    }
}

extension ImageDescriptor: Comparable {
    public static func < (lhs: ImageDescriptor, rhs: ImageDescriptor) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        return (lhs.marketCode ?? "") < (rhs.marketCode ?? "")
    }
}
