import AppKit
import Foundation
import PDFKit
import Vision

enum AttachmentExtractionError: LocalizedError {
    case tooLarge
    case unsupported
    case unreadable

    var errorDescription: String? {
        switch self {
        case .tooLarge: L10n.text("附件超过20 MB，已忽略。", "The attachment exceeds 20 MB and was skipped.")
        case .unsupported: L10n.text("不支持此附件格式。", "This attachment format is not supported.")
        case .unreadable: L10n.text("无法读取附件内容。", "The attachment could not be read.")
        }
    }
}

actor AttachmentTextExtractor {
    func extractText(from attachment: MailAttachment, maximumBytes: Int) throws -> String {
        guard attachment.data.count <= maximumBytes else {
            throw AttachmentExtractionError.tooLarge
        }

        let ext = URL(fileURLWithPath: attachment.filename).pathExtension.lowercased()
        if attachment.mimeType == "application/pdf" || ext == "pdf" {
            return try extractPDF(attachment.data)
        }
        if ext == "docx" || attachment.mimeType == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" {
            return try extractDOCX(attachment.data)
        }
        if attachment.mimeType.hasPrefix("text/") || ["txt", "md", "csv", "rtf"].contains(ext) {
            return try extractPlainText(attachment.data)
        }
        if attachment.mimeType.hasPrefix("image/") || ["png", "jpg", "jpeg", "heic", "tiff"].contains(ext) {
            return try extractImageText(attachment.data)
        }

        throw AttachmentExtractionError.unsupported
    }

    private func extractPDF(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data),
              let text = document.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AttachmentExtractionError.unreadable }
        return text
    }

    private func extractPlainText(_ data: Data) throws -> String {
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .utf16) { return value }
        if let value = String(data: data, encoding: .isoLatin1) { return value }
        throw AttachmentExtractionError.unreadable
    }

    private func extractImageText(_ data: Data) throws -> String {
        guard let image = NSImage(data: data) else {
            throw AttachmentExtractionError.unreadable
        }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw AttachmentExtractionError.unreadable
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw AttachmentExtractionError.unreadable }
        return lines.joined(separator: "\n")
    }

    private func extractDOCX(_ data: Data) throws -> String {
        let fileManager = FileManager.default
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("MailDigest-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = baseURL.appendingPathComponent("attachment.docx")
        let expandedURL = baseURL.appendingPathComponent("expanded", isDirectory: true)

        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseURL) }
        try data.write(to: archiveURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, expandedURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AttachmentExtractionError.unreadable
        }

        let documentURL = expandedURL.appendingPathComponent("word/document.xml")
        let xmlData = try Data(contentsOf: documentURL)
        guard var xml = String(data: xmlData, encoding: .utf8) else {
            throw AttachmentExtractionError.unreadable
        }
        xml = xml.replacingOccurrences(of: "</w:p>", with: "\n")
        xml = xml.replacingOccurrences(of: "</w:tab>", with: "\t")
        xml = xml.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        xml = xml.replacingOccurrences(of: "&amp;", with: "&")
        xml = xml.replacingOccurrences(of: "&lt;", with: "<")
        xml = xml.replacingOccurrences(of: "&gt;", with: ">")
        let cleaned = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw AttachmentExtractionError.unreadable }
        return cleaned
    }
}
