import Foundation
import AppKit
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Update.rawValue
)

protocol UpdateManagerDelegate: AnyObject {
    @MainActor
    func downloadedNewImage()
}

final class UpdateManager: @unchecked Sendable {
    private static let ACTIVITY_IDENTIFIER = "com.2h4u.BingWallpaper.update"

    weak var delegate: UpdateManagerDelegate?
    private let settings = Settings()
    private var activity: NSBackgroundActivityScheduler?
    private var pendingCompletion: NSBackgroundActivityScheduler.CompletionHandler?
    private var consecutiveFailures = 0
    private var isUpdating = false

    private static let RETRY_BASE_INTERVAL: TimeInterval = 30
    private static let RETRY_MAX_INTERVAL: TimeInterval = 30 * 60

    @MainActor
    func start() {
        setupObserver()
        doUpdateOrScheduleActivity()
    }

    @MainActor
    private func doUpdateOrScheduleActivity() {
        if UpdateScheduleManager.isUpdateNecessary() {
            update()
            return
        }

        scheduleNextActivity()
    }

    @MainActor
    private func scheduleNextActivity(overrideInterval: TimeInterval? = nil) {
        let nextFetchInterval = overrideInterval ?? UpdateScheduleManager.nextFetchTimeInterval()
        logger.info("Next update at \(Date().addingTimeInterval(nextFetchInterval), privacy: .public)")

        activity?.invalidate()

        let scheduler = NSBackgroundActivityScheduler(identifier: UpdateManager.ACTIVITY_IDENTIFIER)
        scheduler.repeats = false
        scheduler.interval = nextFetchInterval
        scheduler.tolerance = min(nextFetchInterval / 2, 60 * 30)
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    completion(.finished)
                    return
                }
                self.pendingCompletion = completion
                self.update()
            }
        }

        activity = scheduler
    }
        
    @MainActor
    private func cleanup() {
        // TODO: @2h4u: find entries with same startDate and remove them
        // TODO: @2h4u: probably do this in a migration function in appdelegate
        
        guard let oldestDateStringToKeep = settings.oldestDateStringToKeep() else { return }
        try? Database.instance.deleteImageDescriptors(olderThan: oldestDateStringToKeep)
        FileHandler.deleteOldImages(oldestDateStringToKeep: oldestDateStringToKeep)
    }
    
    private func setupObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(receiveSleepNote),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(receiveWakeNote),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    @MainActor
    @objc func update() {
        guard isUpdating == false else {
            logger.info("An update is already running; coalescing the request")
            return
        }

        isUpdating = true
        logger.info("Updating")
        let marketCode = settings.bingMarketCode

        Task { [weak self] in

            let imageEntries: [DownloadManager.ImageEntry]
            do {
                imageEntries = try await DownloadManager.downloadImageEntries(numberOfImages: 8, marketCode: marketCode)
            } catch {
                logger.error("Failed to download image entries with error: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.finishUpdateWithFailure()
                }
                return
            }

           let descriptors = Database.instance.updateImageDescriptors(from: imageEntries, marketCode: marketCode)

           let missingDescriptors = descriptors
                .filter { $0.image.isOnDisk() == false }

            var imageDownloadFailed = false
            var downloadedAnImage = false
            for descriptor in missingDescriptors {
                do {
                    try await descriptor.image.downloadAndSaveToDisk()
                    downloadedAnImage = true
                } catch {
                    imageDownloadFailed = true
                    logger.error("Failed to download and store image \(descriptor.imageUrl, privacy: .public) with error: \(error.localizedDescription, privacy: .public)")
                }
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if downloadedAnImage {
                    self.delegate?.downloadedNewImage()
                }
                if imageDownloadFailed {
                    self.finishUpdateWithFailure()
                    return
                }

                self.isUpdating = false
                self.settings.lastUpdate = Date()
                self.consecutiveFailures = 0
                self.cleanup()

                let completion = self.pendingCompletion
                self.pendingCompletion = nil
                completion?(.finished)

                self.scheduleNextActivity()
            }
        }
    }

    @MainActor
    private func finishUpdateWithFailure() {
        isUpdating = false
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(.deferred)
        scheduleRetryAfterFailure()
    }

    @MainActor
    private func scheduleRetryAfterFailure() {
        consecutiveFailures += 1
        let exponent = min(consecutiveFailures - 1, 10)
        let backoff = min(
            UpdateManager.RETRY_BASE_INTERVAL * pow(2.0, Double(exponent)),
            UpdateManager.RETRY_MAX_INTERVAL
        )
        logger.info("Update failed (\(self.consecutiveFailures, privacy: .public) in a row), retrying in \(backoff, privacy: .public)s")
        scheduleNextActivity(overrideInterval: backoff)
    }
    
    @MainActor
    @objc func receiveSleepNote(note: NSNotification) {
        activity?.invalidate()
    }

    @MainActor
    @objc func receiveWakeNote(note: NSNotification) {
        doUpdateOrScheduleActivity()
    }
}
