import AppKit
import ImageIO
import Security
import UniformTypeIdentifiers

struct AIGenerationCanvasSnapshot: @unchecked Sendable {
    let documentID: UUID
    let canvasSize: CGSize
    /// The document-space rectangle represented by the generated image.
    let destinationRect: CGRect
    let inputWidth: Int
    let inputHeight: Int
    let imageData: Data
    let maskData: Data?
    let selectionCoverage: CGImage?
}

enum AIGenerationError: LocalizedError {
    case noDocument
    case emptySelection
    case invalidEndpoint
    case missingAPIKey
    case unsupportedImage
    case imageTooLarge
    case maskTooLarge
    case requestTooLarge
    case server(String)
    case emptyResponse
    case documentChanged

    var errorDescription: String? {
        switch self {
        case .noDocument: InterfaceLocalization.string("Open or create a canvas before generating an image.")
        case .emptySelection: InterfaceLocalization.string("The selection is empty. Select an area or deselect before generating.")
        case .invalidEndpoint: InterfaceLocalization.string("Enter an HTTPS API endpoint, or an HTTP endpoint on this Mac.")
        case .missingAPIKey: InterfaceLocalization.string("Enter and save an API key before generating.")
        case .unsupportedImage: InterfaceLocalization.string("The image service returned data that Compositor could not read.")
        case .imageTooLarge: InterfaceLocalization.string("Each source image must be smaller than 50 MB.")
        case .maskTooLarge: InterfaceLocalization.string("The selection mask is larger than 4 MB. Reduce the canvas size or simplify the selection.")
        case .requestTooLarge: InterfaceLocalization.string("The total request is larger than 100 MB. Remove some reference images.")
        case .server(let message): InterfaceLocalization.string(message)
        case .emptyResponse: InterfaceLocalization.string("The image service returned no image.")
        case .documentChanged: InterfaceLocalization.string("The active canvas changed while the image was generating. The result was not inserted.")
        }
    }
}

enum AIGenerationKeychain {
    private static let service = "com.wonderassembly.compositor.image-generation"
    private static let account = "api-key"

    static func load() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AIGenerationError.server(InterfaceLocalization.string("Compositor could not read the API key from Keychain."))
        }
        return value
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AIGenerationError.server(InterfaceLocalization.string("Compositor could not remove the API key from Keychain."))
            }
            return
        }
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw AIGenerationError.server(InterfaceLocalization.string("Compositor could not update the API key in Keychain."))
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AIGenerationError.server(InterfaceLocalization.string("Compositor could not save the API key to Keychain."))
        }
    }
}

enum AIGenerationImageCodec {
    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AIGenerationError.unsupportedImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AIGenerationError.unsupportedImage }
        return data as Data
    }

    /// The edit API treats fully transparent mask pixels as editable, opposite to Compositor's white-selected mask.
    static func transparentEditMaskPNG(from coverage: CGImage) throws -> Data {
        guard coverage.bitsPerComponent == 8, coverage.bitsPerPixel == 8,
              let provider = coverage.dataProvider, let source = provider.data else {
            throw AIGenerationError.unsupportedImage
        }
        let width = coverage.width, height = coverage.height
        var rgba = Data(count: width * height * 4)
        let sourceBytes = CFDataGetBytePtr(source)
        guard let sourceBytes else { throw AIGenerationError.unsupportedImage }
        rgba.withUnsafeMutableBytes { destination in
            guard let bytes = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let input = sourceBytes[y * coverage.bytesPerRow + x]
                    let output = (y * width + x) * 4
                    bytes[output] = 255
                    bytes[output + 1] = 255
                    bytes[output + 2] = 255
                    bytes[output + 3] = 255 - input
                }
            }
        }
        let providerData = rgba as CFData
        guard let imageProvider = CGDataProvider(data: providerData),
              let mask = CGImage(width: width, height: height,
                                 bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: width * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                 provider: imageProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw AIGenerationError.unsupportedImage
        }
        let data = try pngData(mask)
        guard data.count < 4 * 1024 * 1024 else { throw AIGenerationError.maskTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw AIGenerationError.unsupportedImage
        }
        return image
    }

    static func fit(_ image: CGImage, width: Int, height: Int, clip: CGImage? = nil) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        if let clip {
            SelectionClip(rect: CGRect(x: 0, y: 0, width: width, height: height), coverage: clip).apply(to: context)
        }
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.copy)
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let fittedSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let fittedRect = CGRect(x: (CGFloat(width) - fittedSize.width) / 2,
                                y: (CGFloat(height) - fittedSize.height) / 2,
                                width: fittedSize.width, height: fittedSize.height)
        context.draw(image, in: fittedRect)
        context.restoreGState()
        guard let result = context.makeImage() else { throw AIGenerationError.unsupportedImage }
        return result
    }
}

enum AIGenerationClient {
    private struct ImageEditResponse: Decodable {
        struct Output: Decodable {
            let b64_json: String?
            let url: URL?
        }
        let data: [Output]?
    }

    private struct APIErrorResponse: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    static func generate(endpoint: String, model: String, apiKey: String, prompt: String,
                         quality: String, images: [Data], mask: Data?) async throws -> CGImage {
        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointURL = URL(string: endpointText)
        let resolvedEndpoint: String
        if let endpointURL, endpointURL.path.isEmpty || endpointURL.path == "/" {
            resolvedEndpoint = endpointText + "/v1/images/edits"
        } else {
            resolvedEndpoint = endpointText
        }
        guard let url = URL(string: resolvedEndpoint),
              let scheme = url.scheme?.lowercased(), let host = url.host,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())) else {
            throw AIGenerationError.invalidEndpoint
        }
        let localHost = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard localHost || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGenerationError.missingAPIKey
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIGenerationError.server("Describe what you want to generate.")
        }
        guard !images.isEmpty, images.count <= 16 else { throw AIGenerationError.unsupportedImage }
        guard images.allSatisfy({ $0.count < 50 * 1024 * 1024 }) else { throw AIGenerationError.imageTooLarge }
        if let mask, mask.count >= 4 * 1024 * 1024 { throw AIGenerationError.maskTooLarge }

        let boundary = "Compositor-\(UUID().uuidString)"
        var body = Data()
        appendField("model", model, boundary: boundary, to: &body)
        appendField("prompt", prompt, boundary: boundary, to: &body)
        // Keep edit dimensions tied to the input image; some compatible gateways reject "auto".
        appendField("quality", quality, boundary: boundary, to: &body)
        appendField("output_format", "png", boundary: boundary, to: &body)
        for (index, image) in images.enumerated() {
            appendFile("image[]", filename: index == 0 ? "canvas.png" : "reference-\(index).png",
                       mimeType: "image/png", data: image, boundary: boundary, to: &body)
        }
        if let mask {
            appendFile("mask", filename: "selection-mask.png", mimeType: "image/png", data: mask,
                       boundary: boundary, to: &body)
        }
        body.appendUTF8("--\(boundary)--\r\n")
        guard body.count <= 100 * 1024 * 1024 else { throw AIGenerationError.requestTooLarge }

        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.httpBody = body
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        let (responseData, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIGenerationError.server("The image service returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: responseData).error?.message)
                ?? String(data: responseData.prefix(1200), encoding: .utf8)
                ?? "Unknown API error"
            throw AIGenerationError.server("Image API error (HTTP \(http.statusCode)): \(message)")
        }
        guard let result = try? JSONDecoder().decode(ImageEditResponse.self, from: responseData).data?.first else {
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown content type"
            let body = String(data: responseData.prefix(1200), encoding: .utf8) ?? "non-text response"
            throw AIGenerationError.server("The image API response could not be read (\(contentType)): \(body)")
        }
        if let encoded = result.b64_json, let data = Data(base64Encoded: encoded) {
            return try AIGenerationImageCodec.decode(data)
        }
        if let resultURL = result.url {
            guard resultURL.scheme == "https" || resultURL.host == "localhost" || resultURL.host == "127.0.0.1" else {
                throw AIGenerationError.server("The image service returned an insecure image URL.")
            }
            let (data, _) = try await URLSession(configuration: configuration).data(from: resultURL)
            return try AIGenerationImageCodec.decode(data)
        }
        throw AIGenerationError.emptyResponse
    }

    private static func appendField(_ name: String, _ value: String, boundary: String, to body: inout Data) {
        body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    private static func appendFile(_ name: String, filename: String, mimeType: String, data: Data,
                                   boundary: String, to body: inout Data) {
        body.appendUTF8("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendUTF8("\r\n")
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) { append(contentsOf: string.utf8) }
}
