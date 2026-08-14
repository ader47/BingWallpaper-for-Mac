//
//  AppUpdateManager.swift
//  BingWallpaper
//
//  Created by Laurenz Lazarus on 11.12.22.
//

import Foundation
import AppKit
import CryptoKit
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.AppUpdate.rawValue
)

class AppUpdateManager {

    private static let defaultReleaseRepository = "ader47/BingWallpaper-for-Mac"

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    static func currentAppVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func releaseRepository(bundle: Bundle = .main) -> String {
        guard let repository = bundle.object(forInfoDictionaryKey: "BingWallpaperReleaseRepository") as? String,
              isValidReleaseRepository(repository) else {
            return defaultReleaseRepository
        }
        return repository
    }

    static func latestReleaseAPIURL(repository: String) -> URL? {
        guard isValidReleaseRepository(repository) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository)/releases/latest"
        return components.url
    }

    private static func isValidReleaseRepository(_ repository: String) -> Bool {
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            component.isEmpty == false &&
                component.allSatisfy { character in
                    character.isASCII &&
                        (character.isLetter || character.isNumber || "_.-".contains(character))
                } &&
                component.contains(where: { $0 != "." })
        }
    }

    private static func fetchLatestReleaseFromGithub() async -> GitHubRelease? {
        guard let latestReleaseURL = latestReleaseAPIURL(repository: releaseRepository()) else {
            logger.error("The configured GitHub release repository is invalid")
            return nil
        }
        do {
            return try await DownloadManager.downloadJson(
                GitHubRelease.self,
                from: latestReleaseURL,
                headers: [
                    "Accept": "application/vnd.github+json",
                    "User-Agent": "BingWallpaper/\(currentAppVersion())",
                    "X-GitHub-Api-Version": "2022-11-28"
                ]
            )
        } catch {
            logger.error("Failed to fetch the latest GitHub release: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func fetchLatestAppVersionFromGithub() async -> String? {
        return await fetchLatestReleaseFromGithub()?.tagName
    }
    
    private static func newVersionAvailable(_ currentAppVersion: String, _ latestAppVersion: String) -> Bool {
        let currentAppVersion = currentAppVersion.replacingOccurrences(of: "v", with: "")
        let latestAppVersion = latestAppVersion.replacingOccurrences(of: "v", with: "")
        return currentAppVersion.versionCompare(latestAppVersion) == .orderedAscending
    }
    
    static func checkForUpdate(notifyUserAboutNoNewVersion:Bool = false) async {
        guard let latestRelease = await fetchLatestReleaseFromGithub() else {
            logger.error("Failed to fetch latest app version from github")
            return
        }

        let latestGithubAppVersion = latestRelease.tagName
        
        let currentAppVersion = currentAppVersion()
        
        if newVersionAvailable(currentAppVersion, latestGithubAppVersion) == false {
            logger.info("No app update required, \(currentAppVersion, privacy: .public) is already the newest version")
            
            if notifyUserAboutNoNewVersion == true {
                    await showAlreadyUpToDateDialog()
            }
            return
        }
        
        guard let pkgInstaller = await downloadVerifiedInstaller(from: latestRelease) else {
            logger.error("Failed to download and verify the latest app installer")
            return
        }
        
        guard let pkgInstallerPathUrl = FileHandler.savePkgInstallerToDisk(pkgInstaller: pkgInstaller, appVersion: latestGithubAppVersion) else {
            return
        }
        
        if await showShouldUpdateNowDialog(currentAppVersion: currentAppVersion, latestAppVersion: latestGithubAppVersion) == true {
            NSWorkspace.shared.open(pkgInstallerPathUrl)
        }
    }
    
    private static func downloadVerifiedInstaller(from release: GitHubRelease) async -> Data? {
        guard let packageAsset = release.assets.first(where: { $0.name.hasSuffix(".pkg") }),
              let checksumAsset = release.assets.first(where: { $0.name == packageAsset.name + ".sha256" }) else {
            logger.error("Release \(release.tagName, privacy: .public) is missing its installer or SHA-256 asset")
            return nil
        }

        do {
            async let packageData = DownloadManager.downloadPackage(from: packageAsset.browserDownloadUrl)
            async let checksumText = DownloadManager.downloadText(from: checksumAsset.browserDownloadUrl)
            let (installer, checksum) = try await (packageData, checksumText)
            guard verifyChecksum(packageData: installer, checksumText: checksum) else {
                logger.error("SHA-256 verification failed for \(packageAsset.name, privacy: .public)")
                return nil
            }
            return installer
        } catch {
            logger.error("Failed downloading release assets: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func sha256Hex(for data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyChecksum(packageData: Data, checksumText: String) -> Bool {
        guard let expectedChecksum = checksumText
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased(),
              expectedChecksum.count == 64 else {
            return false
        }
        return sha256Hex(for: packageData) == expectedChecksum
    }
    
    @MainActor
    private static func showShouldUpdateNowDialog(currentAppVersion: String, latestAppVersion: String) -> Bool {
        let currentAppVersion = currentAppVersion.replacingOccurrences(of: "v", with: "")
        let latestAppVersion = latestAppVersion.replacingOccurrences(of: "v", with: "")
        let alert = NSAlert()
        alert.messageText = "New version of BingWallpaper available"
        alert.informativeText = "Do you want to update now?\nCurrent version: \(currentAppVersion)\nNew version: \(latestAppVersion)"
        let updateButton = alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        
        alert.window.defaultButtonCell = updateButton.cell as? NSButtonCell
        
        return alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn
    }
    
    @MainActor
    private static func showAlreadyUpToDateDialog() {
        let alert = NSAlert()
        alert.messageText = "BingWallpaper already up to date"
        alert.informativeText = "There is no new version of BingWallpaper available"
        let updateButton = alert.addButton(withTitle: "Ok")
        alert.alertStyle = .informational
        
        alert.window.defaultButtonCell = updateButton.cell as? NSButtonCell
        
        alert.runModal()
    }
    
}
