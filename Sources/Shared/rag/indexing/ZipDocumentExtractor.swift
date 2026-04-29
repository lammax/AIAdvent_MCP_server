import Foundation
import ZIPFoundation

public protocol ZipDocumentExtractorProtocol: Sendable {
    func extract(_ zipURL: URL) throws -> URL
}

public struct ZipDocumentExtractor: ZipDocumentExtractorProtocol {
    public init() {}

    public func extract(_ zipURL: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("rag-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        let archive = try Archive(url: zipURL, accessMode: .read)

        for entry in archive {
            guard isSafeEntryPath(entry.path) else {
                throw ZipDocumentExtractorError.unsafeEntryPath(entry.path)
            }

            let entryURL = destination.appendingPathComponent(entry.path)

            if entry.type == .directory {
                try FileManager.default.createDirectory(
                    at: entryURL,
                    withIntermediateDirectories: true
                )
                continue
            }

            try FileManager.default.createDirectory(
                at: entryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            _ = try archive.extract(entry, to: entryURL)
        }

        return destination
    }

    private func isSafeEntryPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/")
            && !components.contains("..")
            && !path.contains("\0")
    }
}

public enum ZipDocumentExtractorError: LocalizedError {
    case unsafeEntryPath(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeEntryPath(let path):
            return "Unsafe zip entry path: \(path)"
        }
    }
}
