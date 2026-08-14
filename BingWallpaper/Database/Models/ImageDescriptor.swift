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
    @NSManaged var startDate: String
    @NSManaged var endDate: String
    @NSManaged var imageUrl: URL
    @NSManaged var descriptionString: String
    @NSManaged var copyrightUrl: URL
    @NSManaged var marketCode: String?
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
    
    static func == (lhs: ImageDescriptor, rhs: ImageDescriptor) -> Bool {
        return lhs.startDate == rhs.startDate && lhs.marketCode == rhs.marketCode
    }
    
    static func instantiate(from entry: DownloadManager.ImageEntry, marketCode: String?, in managedContext: NSManagedObjectContext) -> ImageDescriptor {
        let entity = NSEntityDescription.entity(forEntityName: "ImageDescriptor", in: managedContext)!
        let imageDescriptor = ImageDescriptor(entity: entity, insertInto: managedContext)
        imageDescriptor.startDate = entry.startdate
        imageDescriptor.endDate = entry.enddate
        imageDescriptor.imageUrl = URL(string: "https://www.bing.com" + entry.url.replacingOccurrences(of: "1920x1080", with: "UHD"))!
        imageDescriptor.descriptionString = entry.copyright
        imageDescriptor.copyrightUrl = URL(string: entry.copyrightlink)!
        imageDescriptor.marketCode = marketCode
        return imageDescriptor
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
