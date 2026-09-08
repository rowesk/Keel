import Foundation
import UniformTypeIdentifiers

public enum KeelDownloadNaming {
    public static func filename(
        suggestedFilename: String?,
        responseSuggestedFilename: String? = nil,
        responseURL: URL? = nil,
        mimeType: String?,
        fallbackName: String = "download"
    ) -> String {
        let rawName = [
            suggestedFilename,
            responseSuggestedFilename,
            responseURL?.lastPathComponent,
            fallbackName,
            "download",
        ]
        .compactMap(normalizedFilename)
        .first ?? "download"
        let existingExtension = (rawName as NSString).pathExtension
        guard existingExtension.isEmpty, let inferredFileExtension = inferredExtension(forMIMEType: mimeType) else {
            return rawName
        }
        return rawName + "." + inferredFileExtension
    }

    public static func inferredExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let normalizedMIMEType = mimeType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? mimeType
        if let extensionFromType = UTType(mimeType: normalizedMIMEType)?.preferredFilenameExtension {
            return extensionFromType
        }

        switch normalizedMIMEType {
        case "application/pdf": return "pdf"
        case "application/zip": return "zip"
        case "application/gzip", "application/x-gzip": return "gz"
        case "application/x-7z-compressed": return "7z"
        case "application/x-rar-compressed": return "rar"
        case "application/x-tar": return "tar"
        case "application/vnd.apple.installer+xml": return "pkg"
        case "application/vnd.android.package-archive": return "apk"
        case "application/octet-stream": return nil
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "text/html": return "html"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/ogg": return "ogg"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.ms-powerpoint": return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        default: return nil
        }
    }

    private static func normalizedFilename(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let decoded = rawValue.removingPercentEncoding ?? rawValue
        let filename = decoded
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let filename,
              !filename.isEmpty,
              filename != ".",
              filename != "..",
              filename.caseInsensitiveCompare("unknown") != .orderedSame
        else { return nil }
        return filename
    }
}
