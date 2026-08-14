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
    static let instance = Database()
    
    private init() { }
    
    @MainActor
    func allImageDescriptors() -> [ImageDescriptor] {
        let fetchRequest = NSFetchRequest<ImageDescriptor>(entityName: "ImageDescriptor")
        
        do {
            return try persistentContainer.viewContext
                .fetch(fetchRequest)
                .sorted()
        } catch let error as NSError {
            logger.error("Could not fetch. \(error, privacy: .public), \(error.userInfo, privacy: .public)")
            return []
        }
    }

    @MainActor
    func allImageDescriptors(marketCode: String?) -> [ImageDescriptor] {
        return allImageDescriptors().filter { $0.marketCode == marketCode }
    }
    
    @MainActor
    @discardableResult
    func deleteImageDescriptors(
        olderThan oldestDateStringToKeep: String,
        preserving wallpaperIDs: Set<String> = []
    ) throws -> Set<String> {
        let managedContext = persistentContainer.viewContext
        let descriptorsToDelete = allImageDescriptors()
            .filter {
                $0.startDate <= oldestDateStringToKeep &&
                    wallpaperIDs.contains($0.wallpaperIdentifier) == false
            }
        let deletedFileNames = Set(descriptorsToDelete.map { $0.image.fileName })
        descriptorsToDelete.forEach { managedContext.delete($0) }
        
        try managedContext.save()
        return deletedFileNames
    }
    
    @MainActor
    func updateImageDescriptors(from imageEntries: [DownloadManager.ImageEntry], marketCode: String?) -> [ImageDescriptor] {
        let managedContext = persistentContainer.viewContext
        let preservedStartDates = allImageDescriptors(marketCode: marketCode)
            .map { $0.startDate }
        
        imageEntries
            .filter { imageEntry in preservedStartDates.contains(imageEntry.startdate) == false }
            .forEach { image in
                _ = ImageDescriptor.instantiate(from: image, marketCode: marketCode, in: managedContext)
            }
        
        do {
            try managedContext.save()
        } catch let error as NSError {
            logger.error("Could not save. \(error, privacy: .public), \(error.userInfo, privacy: .public)")
        }
        
        // Return all descriptors for this market so missing files are retried,
        // even when their metadata was saved by an earlier update.
        return allImageDescriptors(marketCode: marketCode)
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
