import Foundation
import AppKit
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Update.rawValue
)

enum WallpaperUpdatePhase: Equatable {
    case idle
    case updating
    case succeeded
    case retrying
    case failed
}

enum WallpaperUpdateFailureStage: Equatable {
    case metadata
    case images

    var title: String {
        switch self {
        case .metadata:
            return "Wallpaper list"
        case .images:
            return "Image download"
        }
    }
}

struct WallpaperUpdateFailure: Equatable {
    let stage: WallpaperUpdateFailureStage
    let message: String
    let occurredAt: Date
}

struct WallpaperUpdateStatus: Equatable {
    let phase: WallpaperUpdatePhase
    let lastSuccessAt: Date?
    let lastAttemptAt: Date?
    let nextAttemptAt: Date?
    let failure: WallpaperUpdateFailure?
    let consecutiveFailures: Int

    var menuTitle: String {
        switch phase {
        case .idle, .succeeded:
            return "Update Status: Up to Date"
        case .updating:
            return "Update Status: Updating…"
        case .retrying:
            return "Update Status: Failed — Retry Scheduled"
        case .failed:
            return "Update Status: Failed"
        }
    }
}

protocol UpdateManagerDelegate: AnyObject {
    @MainActor
    func downloadedNewImage()
    @MainActor
    func updateStatusDidChange(_ status: WallpaperUpdateStatus)
}

final class UpdateManager: @unchecked Sendable {
    private static let ACTIVITY_IDENTIFIER = "com.2h4u.BingWallpaper.update"

    weak var delegate: UpdateManagerDelegate?
    private let settings: Settings
    private var activity: NSBackgroundActivityScheduler?
    private var pendingCompletion: NSBackgroundActivityScheduler.CompletionHandler?
    private var consecutiveFailures = 0
    private var isUpdating = false
    private(set) var status: WallpaperUpdateStatus

    private static let RETRY_BASE_INTERVAL: TimeInterval = 30
    private static let RETRY_MAX_INTERVAL: TimeInterval = 30 * 60

    init(settings: Settings = Settings()) {
        self.settings = settings
        let lastUpdate = settings.lastUpdate
        let lastSuccessAt = lastUpdate == Date.distantPast ? nil : lastUpdate
        self.status = WallpaperUpdateStatus(
            phase: .idle,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            failure: nil,
            consecutiveFailures: 0
        )
    }

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

        let nextUpdateAt = scheduleNextActivity()
        publishStatus(WallpaperUpdateStatus(
            phase: .idle,
            lastSuccessAt: lastSuccessfulUpdate,
            lastAttemptAt: status.lastAttemptAt,
            nextAttemptAt: nextUpdateAt,
            failure: nil,
            consecutiveFailures: 0
        ))
    }

    @MainActor
    @discardableResult
    private func scheduleNextActivity(overrideInterval: TimeInterval? = nil) -> Date {
        let nextFetchInterval = overrideInterval ?? UpdateScheduleManager.nextFetchTimeInterval()
        let nextUpdateAt = Date().addingTimeInterval(nextFetchInterval)
        logger.info("Next update at \(nextUpdateAt, privacy: .public)")

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
        return nextUpdateAt
    }
        
    @MainActor
    private func cleanup() {
        // TODO: @2h4u: find entries with same startDate and remove them
        // TODO: @2h4u: probably do this in a migration function in appdelegate
        
        guard let oldestDateStringToKeep = settings.oldestDateStringToKeep() else { return }
        var preservedIDs = settings.favoriteWallpaperIDs
        if let pinnedWallpaperID = settings.pinnedWallpaperID {
            preservedIDs.insert(pinnedWallpaperID)
        }
        for profile in settings.wallpaperDisplayProfiles.values {
            if let pinnedWallpaperID = profile.pinnedWallpaperID {
                preservedIDs.insert(pinnedWallpaperID)
            }
        }
        let preservedFileNames = Set(
            Database.instance.allImageDescriptors()
                .filter { preservedIDs.contains($0.wallpaperIdentifier) }
                .map { $0.image.fileName }
        )
        try? Database.instance.deleteImageDescriptors(
            olderThan: oldestDateStringToKeep,
            preserving: preservedIDs
        )
        FileHandler.deleteOldImages(
            oldestDateStringToKeep: oldestDateStringToKeep,
            preservingFileNames: preservedFileNames
        )
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

        activity?.invalidate()
        activity = nil
        isUpdating = true
        let attemptDate = Date()
        publishStatus(WallpaperUpdateStatus(
            phase: .updating,
            lastSuccessAt: lastSuccessfulUpdate,
            lastAttemptAt: attemptDate,
            nextAttemptAt: nil,
            failure: nil,
            consecutiveFailures: consecutiveFailures
        ))
        logger.info("Updating")
        let marketCodes = settings.requiredBingMarketCodes

        Task { [weak self] in
            var imageDownloadFailed = false
            var firstImageDownloadError: Error?
            var downloadedAnImage = false

            for marketCode in marketCodes {
                let imageEntries: [DownloadManager.ImageEntry]
                do {
                    imageEntries = try await DownloadManager.downloadImageEntries(
                        numberOfImages: 8,
                        marketCode: marketCode
                    )
                } catch {
                    logger.error("Failed to download image entries for market \(marketCode ?? "automatic", privacy: .public) with error: \(error.localizedDescription, privacy: .public)")
                    await MainActor.run { [weak self] in
                        if downloadedAnImage {
                            self?.delegate?.downloadedNewImage()
                        }
                        self?.finishUpdateWithFailure(stage: .metadata, error: error)
                    }
                    return
                }

                let descriptors = Database.instance.updateImageDescriptors(
                    from: imageEntries,
                    marketCode: marketCode
                )
                let missingDescriptors = descriptors
                    .filter { $0.image.isOnDisk() == false }

                for descriptor in missingDescriptors {
                    do {
                        try await descriptor.image.downloadAndSaveToDisk()
                        downloadedAnImage = true
                    } catch {
                        imageDownloadFailed = true
                        if firstImageDownloadError == nil {
                            firstImageDownloadError = error
                        }
                        logger.error("Failed to download and store image \(descriptor.imageUrl, privacy: .public) with error: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if downloadedAnImage {
                    self.delegate?.downloadedNewImage()
                }
                if imageDownloadFailed {
                    self.finishUpdateWithFailure(
                        stage: .images,
                        error: firstImageDownloadError ?? ImageError.dataNotValid
                    )
                    return
                }

                self.isUpdating = false
                let completedAt = Date()
                self.settings.lastUpdate = completedAt
                self.consecutiveFailures = 0
                self.cleanup()

                let completion = self.pendingCompletion
                self.pendingCompletion = nil
                completion?(.finished)

                let nextUpdateAt = self.scheduleNextActivity()
                self.publishStatus(WallpaperUpdateStatus(
                    phase: .succeeded,
                    lastSuccessAt: completedAt,
                    lastAttemptAt: attemptDate,
                    nextAttemptAt: nextUpdateAt,
                    failure: nil,
                    consecutiveFailures: 0
                ))
            }
        }
    }

    @MainActor
    private func finishUpdateWithFailure(stage: WallpaperUpdateFailureStage, error: Error) {
        isUpdating = false
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(.deferred)
        scheduleRetryAfterFailure(stage: stage, error: error)
    }

    @MainActor
    private func scheduleRetryAfterFailure(stage: WallpaperUpdateFailureStage, error: Error) {
        consecutiveFailures += 1
        let backoff = Self.retryInterval(forFailureCount: consecutiveFailures)
        logger.info("Update failed (\(self.consecutiveFailures, privacy: .public) in a row), retrying in \(backoff, privacy: .public)s")
        let failureDate = Date()
        let nextRetryAt = scheduleNextActivity(overrideInterval: backoff)
        publishStatus(WallpaperUpdateStatus(
            phase: .retrying,
            lastSuccessAt: lastSuccessfulUpdate,
            lastAttemptAt: status.lastAttemptAt ?? failureDate,
            nextAttemptAt: nextRetryAt,
            failure: WallpaperUpdateFailure(
                stage: stage,
                message: error.localizedDescription,
                occurredAt: failureDate
            ),
            consecutiveFailures: consecutiveFailures
        ))
    }

    static func retryInterval(forFailureCount failureCount: Int) -> TimeInterval {
        let exponent = min(max(failureCount, 1) - 1, 10)
        return min(
            RETRY_BASE_INTERVAL * pow(2.0, Double(exponent)),
            RETRY_MAX_INTERVAL
        )
    }

    private var lastSuccessfulUpdate: Date? {
        let lastUpdate = settings.lastUpdate
        return lastUpdate == Date.distantPast ? nil : lastUpdate
    }

    @MainActor
    private func publishStatus(_ newStatus: WallpaperUpdateStatus) {
        status = newStatus
        delegate?.updateStatusDidChange(newStatus)
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
