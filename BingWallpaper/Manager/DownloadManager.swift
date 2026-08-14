import Foundation
import ImageIO

class DownloadManager {

    enum Error: LocalizedError {
        case nonHttpResponse
        case httpStatus(Int)
        case unexpectedContentType(String?)
        case invalidText
        case invalidImage
        case invalidPackage

        var errorDescription: String? {
            switch self {
            case .nonHttpResponse:
                return "The server response was not HTTP"
            case .httpStatus(let statusCode):
                return "The server returned HTTP \(statusCode)"
            case .unexpectedContentType(let contentType):
                return "Unexpected content type: \(contentType ?? "missing")"
            case .invalidText:
                return "The response was not valid UTF-8 text"
            case .invalidImage:
                return "The downloaded data was not a valid image"
            case .invalidPackage:
                return "The downloaded data was not a valid installer package"
            }
        }
    }
    
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
    
    private static func downloadData(from url: URL, headers: [String: String] = [:]) async throws -> DownloadResponse {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validateHttpResponse(urlResponse)
        return DownloadResponse(data: data, urlResponse: urlResponse)
    }
    
    static func validateHttpResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.nonHttpResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Error.httpStatus(httpResponse.statusCode)
        }
    }

    private static func validateContentType(_ response: URLResponse, prefixes: [String]) throws {
        guard let mimeType = response.mimeType,
              prefixes.contains(where: { mimeType.hasPrefix($0) }) else {
            throw Error.unexpectedContentType(response.mimeType)
        }
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
        try validateContentType(response.urlResponse, prefixes: ["application/json", "text/json", "application/vnd.github+json"])
        return try JSONDecoder().decode(ImageArchive.self, from: response.data).images
    }

    static func downloadJson<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:]) async throws -> T {
        let response = try await downloadData(from: url, headers: headers)
        try validateContentType(response.urlResponse, prefixes: ["application/json", "text/json", "application/vnd.github+json"])
        return try JSONDecoder().decode(type, from: response.data)
    }
    
    static func downloadText(from url: URL) async throws -> String {
        let response = try await downloadData(from: url)
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw Error.invalidText
        }
        return text
    }

    static func downloadImage(from url: URL) async throws -> Data {
        let response = try await downloadData(from: url)
        try validateContentType(response.urlResponse, prefixes: ["image/"])
        guard isValidImageData(response.data) else {
            throw Error.invalidImage
        }
        return response.data
    }

    static func isValidImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func downloadPackage(from url: URL) async throws -> Data {
        let response = try await downloadData(from: url)
        guard isValidInstallerPackage(response.data) else {
            throw Error.invalidPackage
        }
        return response.data
    }

    static func isValidInstallerPackage(_ data: Data) -> Bool {
        // Flat .pkg installers are XAR archives and begin with the ASCII magic `xar!`.
        return data.starts(with: [0x78, 0x61, 0x72, 0x21])
    }
}
