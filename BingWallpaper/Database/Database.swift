//
//  Database.swift
//  BingWallpaper
//
//  Created by Laurenz Lazarus on 24.03.24.
//

import Foundation
import Cocoa
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Database.rawValue
)

class Database {
    struct ImageDescriptorUpdate {
        let descriptors: [ImageDescriptor]
        let wallpaperIDsRequiringDownload: Set<String>
    }

    static let instance = Database()
    
    private init() { }
    
    @MainActor
    func allImageDescriptors() -> [ImageDescriptor] {
        return fetchImageDescriptors()
    }

    @MainActor
    func allImageDescriptors(marketCode: String?) -> [ImageDescriptor] {
        return fetchImageDescriptors(predicate: marketPredicate(marketCode))
    }

    @MainActor
    private func fetchImageDescriptors(predicate: NSPredicate? = nil) -> [ImageDescriptor] {
        let fetchRequest = NSFetchRequest<ImageDescriptor>(entityName: "ImageDescriptor")
        fetchRequest.predicate = predicate
        fetchRequest.sortDescriptors = [
            NSSortDescriptor(key: "startDate", ascending: true),
            NSSortDescriptor(key: "marketCode", ascending: true)
        ]
        
        do {
            return try persistentContainer.viewContext.fetch(fetchRequest)
        } catch let error as NSError {
            logger.error("Could not fetch. \(error, privacy: .public), \(error.userInfo, privacy: .public)")
            return []
        }
    }

    private func marketPredicate(_ marketCode: String?) -> NSPredicate {
        if let marketCode {
            return NSPredicate(format: "marketCode == %@", marketCode)
        }
        return NSPredicate(format: "marketCode == nil")
    }
    
    @MainActor
    @discardableResult
    func deleteImageDescriptors(
        olderThan oldestDateStringToKeep: String,
        preserving wallpaperIDs: Set<String> = []
    ) throws -> Set<String> {
        let managedContext = persistentContainer.viewContext
        let candidates = fetchImageDescriptors(
            predicate: NSPredicate(format: "startDate <= %@", oldestDateStringToKeep)
        )
        let descriptorsToDelete = candidates
            .filter {
                wallpaperIDs.contains($0.wallpaperIdentifier) == false
            }
        let deletedFileNames = Set(descriptorsToDelete.map { $0.image.fileName })
        descriptorsToDelete.forEach { managedContext.delete($0) }
        
        try managedContext.save()
        return deletedFileNames
    }

    @MainActor
    func deleteAllImageDescriptors() throws {
        let managedContext = persistentContainer.viewContext
        allImageDescriptors().forEach { managedContext.delete($0) }
        try managedContext.save()
    }
    
    @MainActor
    func updateImageDescriptors(
        from imageEntries: [DownloadManager.ImageEntry],
        marketCode: String?
    ) -> ImageDescriptorUpdate {
        let managedContext = persistentContainer.viewContext
        let requestedStartDates = Set(imageEntries.map { $0.startdate })
        var descriptorByStartDate = allImageDescriptors(marketCode: marketCode)
            .reduce(into: [String: ImageDescriptor]()) { descriptors, descriptor in
                descriptors[descriptor.startDate] = descriptor
            }
        var wallpaperIDsRequiringDownload = Set<String>()
        
        for image in imageEntries {
            do {
                if let existingDescriptor = descriptorByStartDate[image.startdate] {
                    if try existingDescriptor.update(from: image) {
                        wallpaperIDsRequiringDownload.insert(existingDescriptor.wallpaperIdentifier)
                    }
                } else {
                    let descriptor = try ImageDescriptor.instantiate(
                        from: image,
                        marketCode: marketCode,
                        in: managedContext
                    )
                    descriptorByStartDate[descriptor.startDate] = descriptor
                }
            } catch {
                logger.error("Skipping invalid Bing wallpaper metadata: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        do {
            try managedContext.save()
        } catch let error as NSError {
            logger.error("Could not save. \(error, privacy: .public), \(error.userInfo, privacy: .public)")
        }
        
        // Retry missing files while they are still part of Bing's current
        // archive response. Historical descriptors must not keep an otherwise
        // healthy update in a permanent retry loop when their remote URL expires.
        let currentDescriptors: [ImageDescriptor]
        if requestedStartDates.isEmpty {
            currentDescriptors = []
        } else {
            currentDescriptors = fetchImageDescriptors(
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    marketPredicate(marketCode),
                    NSPredicate(format: "startDate IN %@", Array(requestedStartDates))
                ])
            )
        }
        return ImageDescriptorUpdate(
            descriptors: currentDescriptors,
            wallpaperIDsRequiringDownload: wallpaperIDsRequiringDownload
        )
    }
    
    
    // MARK: - Core Data stack
    
    private func entityDescription() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "ImageDescriptor"
        entity.managedObjectClassName = NSStringFromClass(ImageDescriptor.self)
        
        // Attributes
        let startDateAttr = NSAttributeDescription()
        startDateAttr.name = "startDate"
        startDateAttr.attributeType = .stringAttributeType
        startDateAttr.isOptional = false
        
        let endDateAttr = NSAttributeDescription()
        endDateAttr.name = "endDate"
        endDateAttr.attributeType = .stringAttributeType
        endDateAttr.isOptional = false
        
        let imageUrlAttr = NSAttributeDescription()
        imageUrlAttr.name = "imageUrl"
        imageUrlAttr.attributeType = .URIAttributeType
        imageUrlAttr.isOptional = false
        
        let descriptionStringAttr = NSAttributeDescription()
        descriptionStringAttr.name = "descriptionString"
        descriptionStringAttr.attributeType = .stringAttributeType
        descriptionStringAttr.isOptional = false
        
        let copyrightUrlAttr = NSAttributeDescription()
        copyrightUrlAttr.name = "copyrightUrl"
        copyrightUrlAttr.attributeType = .URIAttributeType
        copyrightUrlAttr.isOptional = false

        let marketCodeAttr = NSAttributeDescription()
        marketCodeAttr.name = "marketCode"
        marketCodeAttr.attributeType = .stringAttributeType
        marketCodeAttr.isOptional = true
        
        entity.properties = [
            startDateAttr,
            endDateAttr,
            imageUrlAttr,
            descriptionStringAttr,
            copyrightUrlAttr,
            marketCodeAttr
        ]
        
        return entity
    }
    
    private func managedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.entities = [entityDescription()]
        return model
    }
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: managedObjectModel())
        
        container.loadPersistentStores(completionHandler: { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        return container
    }()
}
