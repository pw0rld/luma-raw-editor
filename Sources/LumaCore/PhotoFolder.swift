import Foundation
import UniformTypeIdentifiers
import ImageIO

public enum PhotoFolder {
    // Enumerate names only. Decoding and hashing are deferred until selection.
    public static func scan(_ folder: URL, recursive: Bool) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let supported = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) }
        let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "raw", "rwl", "3fr", "iiq"]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        var scanError: Error?
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: options, errorHandler: { _, error in
                  scanError = error; return false
              }) else { throw EditorError.message("无法读取所选文件夹。") }
        var files = Set<URL>()
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let type = UTType(filenameExtension: ext)
            if rawExtensions.contains(ext) || (type.map { t in supported.contains { t.conforms(to: $0) } } ?? false) {
                files.insert(url.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        if let scanError { throw scanError }
        return files.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}
