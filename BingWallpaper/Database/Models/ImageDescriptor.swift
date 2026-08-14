import AppKit
import CoreData
import Foundation

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
