import Cocoa
import Foundation
import OSLog

private let logger = Logger(
    subsystem: Logging.subsystem,
    category: Logging.Category.Download.rawValue
)

class DownloadManager {
    
    struct ImageArchive: Codable {
        let images: [ImageEntry]
    }
    
    struct ImageEntry: Codable {
        let url: String
        let enddate: String
        let startdate: String
        let copyright: String
        let copyrightlink: String
    }
    
    private static func downloadData(from url: URL) async throws-> DownloadResponse {
        let (data, urlResponse) = try await URLSession.shared.data(from: url)
        return DownloadResponse(data: data, urlResponse: urlResponse)
    }
    
    private static func downloadHttpHead(from url: URL) async throws -> DownloadResponse {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "HEAD"
        let (data, urlResponse) = try await URLSession.shared.data(for: urlRequest)
        return DownloadResponse(data: data, urlResponse: urlResponse)
    }
    
    static func imageArchiveUrl(numberOfImages: Int, marketCode: String?) -> URL {
        var components = URLComponents(string: "https://www.bing.com/HPImageArchive.aspx")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "js"),
            URLQueryItem(name: "n", value: String(numberOfImages)),
            URLQueryItem(name: "idx", value: "0")
        ]
        if let marketCode {
            components.queryItems?.append(URLQueryItem(name: "mkt", value: marketCode))
        }
        return components.url!
    }

    static func downloadImageEntries(numberOfImages: Int, marketCode: String?) async throws -> [ImageEntry] {
        // TODO: @2h4u: idx is the start index of the batch of image descriptors that is downloaded, maybe add support for it so more images from the past can be used?
        let response = try await downloadData(from: imageArchiveUrl(numberOfImages: numberOfImages, marketCode: marketCode))
        return try JSONDecoder().decode(ImageArchive.self, from: response.data).images
    }
    
    static func downloadHtml(from url: URL) async -> String? {
        do {
            let response = try await downloadData(from: url)
            return String(data: response.data, encoding: .utf8)
        } catch let error {
            logger.error("Failed to download HTML from \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    static func downloadHtmlHeaders(from url: URL) async -> URLResponse? {
        do {
            return try await downloadHttpHead(from: url).urlResponse
        } catch let error {
            logger.error("Failed to download HTML headers from \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    static func downloadBinary(from url: URL) async throws -> Data {
        return try await downloadData(from: url).data
    }
}
