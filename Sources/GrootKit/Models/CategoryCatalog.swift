import Foundation

/// A user-defined content category, on top of the built-in set. Persisted by
/// `SettingsStore` as JSON, so it is `Codable`; `Identifiable` for future
/// list-editing UI.
public struct CustomCategory: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// The set of categories the `CategorizationAgent` is allowed to choose from:
/// a fixed built-in list plus the user's custom categories.
///
/// Pure and value-typed → the whole thing is unit-tested with no I/O. The
/// agent asks it for `allowedNames` (to constrain the model) and for
/// `folderName(for:)` (to place the file). A hallucinated category can never
/// reach `FileService` because `CategorizerUseCase` validates the model's answer
/// against `allowedNames` before returning.
public struct CategoryCatalog: Sendable, Equatable {
    /// Meaningful, content-derived top-level buckets. Deliberately broad — the
    /// model picks among these, so more than ~10 hurts precision.
    public static let builtInNames: [String] = [
        "Research", "Finance", "Career", "Legal",
        "Personal", "Receipts", "Health", "Travel"
    ]

    public var custom: [CustomCategory]

    public init(custom: [CustomCategory] = []) {
        self.custom = custom
    }

    /// Built-ins first, then custom names, de-duplicated case-insensitively while
    /// preserving first-seen order and spelling.
    public var allowedNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in Self.builtInNames + custom.map(\.name) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { result.append(trimmed) }
        }
        return result
    }

    /// Folder name a category maps to — sanitized so a custom category can never
    /// produce an illegal path component. Reuses the shared `FilenameSanitizer`.
    public func folderName(for category: String) -> String {
        let safe = FilenameSanitizer.sanitize(category)
        return safe.isEmpty ? "Uncategorized" : safe
    }

    // MARK: Mutations (value semantics — return a new catalog)

    /// Add a custom category. No-op if a category with the same name (ignoring
    /// case) already exists, built-in or custom.
    public func adding(_ name: String) -> CategoryCatalog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        guard !allowedNames.contains(where: { $0.lowercased() == trimmed.lowercased() }) else {
            return self
        }
        var copy = self
        copy.custom.append(CustomCategory(name: trimmed))
        return copy
    }

    /// Rename a custom category by id.
    public func renaming(_ id: UUID, to name: String) -> CategoryCatalog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        var copy = self
        if let idx = copy.custom.firstIndex(where: { $0.id == id }) {
            copy.custom[idx].name = trimmed
        }
        return copy
    }

    /// Remove a custom category by id. Built-ins cannot be removed. Existing
    /// files/folders on disk are untouched — this only affects future decisions.
    public func removing(_ id: UUID) -> CategoryCatalog {
        var copy = self
        copy.custom.removeAll { $0.id == id }
        return copy
    }
}
