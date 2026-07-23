import Foundation

/// Coarse content category derived from a file's extension. Used by the
/// Downloads Organizer (and later the AI Categorization agent as a fallback) to
/// decide which folder a file belongs in. Pure and table-driven → unit-tested.
public enum FileCategory: String, Sendable, CaseIterable {
    case archives
    case installers
    case documents
    case pictures
    case media
    case audio
    case code
    case other

    /// Human folder name (e.g. "Archives").
    public var folderName: String { rawValue.capitalized }

    private static let table: [FileCategory: Set<String>] = [
        .archives:   ["zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz"],
        .installers: ["dmg", "pkg", "mpkg", "app", "iso"],
        .documents:  ["pdf", "doc", "docx", "txt", "rtf", "md", "pages", "key",
                      "ppt", "pptx", "xls", "xlsx", "csv", "epub"],
        .pictures:   ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"],
        .media:      ["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv", "flv"],
        .audio:      ["mp3", "wav", "aac", "flac", "m4a", "aiff", "ogg"],
        .code:       ["swift", "py", "js", "ts", "java", "kt", "c", "h", "cpp",
                      "go", "rs", "rb", "php", "sh", "json", "yaml", "yml"],
    ]

    /// Category for a file extension (case-insensitive, leading dot tolerated).
    public static func forExtension(_ ext: String) -> FileCategory {
        let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for (category, exts) in table where exts.contains(normalized) {
            return category
        }
        return .other
    }

    /// Category for a URL.
    public static func forURL(_ url: URL) -> FileCategory {
        forExtension(url.pathExtension)
    }

    /// The set of folder names the organizer manages — used to detect files that
    /// are already sorted (so we don't re-organize our own output).
    public static var allFolderNames: Set<String> {
        Set(allCases.map(\.folderName))
    }
}
