import Foundation

/// Produces a non-clobbering destination URL by appending " 2", " 3", … before
/// the extension until the path is free. Shared by every agent that moves files.
public enum DestinationResolver {
    public static func collisionSafe(for filename: String, in folder: URL) -> URL {
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? "file" : base
        let fm = FileManager.default

        func url(_ name: String) -> URL {
            let withName = folder.appendingPathComponent(name)
            return ext.isEmpty ? withName : withName.appendingPathExtension(ext)
        }

        var candidate = url(safeBase)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = url("\(safeBase) \(counter)")
            counter += 1
        }
        return candidate
    }
}
