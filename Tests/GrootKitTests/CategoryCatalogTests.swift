import XCTest
@testable import GrootKit

final class CategoryCatalogTests: XCTestCase {

    func testBuiltInsPresentByDefault() {
        let catalog = CategoryCatalog()
        XCTAssertEqual(catalog.allowedNames, CategoryCatalog.builtInNames)
        XCTAssertTrue(catalog.allowedNames.contains("Finance"))
    }

    func testFolderNameSanitizes() {
        let catalog = CategoryCatalog()
        XCTAssertEqual(catalog.folderName(for: "Finance"), "Finance")
        // Illegal path characters are stripped.
        XCTAssertEqual(catalog.folderName(for: "Tax/2024"), "Tax 2024")
        // An all-illegal / empty name never yields an empty folder component.
        XCTAssertEqual(catalog.folderName(for: "///"), "Uncategorized")
    }

    func testAddingCustomCategory() {
        let catalog = CategoryCatalog().adding("Invoices")
        XCTAssertTrue(catalog.allowedNames.contains("Invoices"))
        XCTAssertEqual(catalog.custom.count, 1)
    }

    func testAddingDuplicateIsIgnoredCaseInsensitively() {
        // Duplicates of a built-in or an existing custom category are no-ops.
        let catalog = CategoryCatalog()
            .adding("finance")       // dup of built-in "Finance"
            .adding("Invoices")
            .adding("INVOICES")      // dup of custom "Invoices"
        XCTAssertEqual(catalog.custom.count, 1)
        XCTAssertEqual(catalog.custom.first?.name, "Invoices")
    }

    func testAddingEmptyIsIgnored() {
        let catalog = CategoryCatalog().adding("   ")
        XCTAssertTrue(catalog.custom.isEmpty)
    }

    func testRenamingAndRemoving() {
        var catalog = CategoryCatalog().adding("Invoices")
        let id = try! XCTUnwrap(catalog.custom.first?.id)

        catalog = catalog.renaming(id, to: "Receipts Archive")
        XCTAssertEqual(catalog.custom.first?.name, "Receipts Archive")

        catalog = catalog.removing(id)
        XCTAssertTrue(catalog.custom.isEmpty)
        // Built-ins are unaffected by removals.
        XCTAssertEqual(catalog.allowedNames, CategoryCatalog.builtInNames)
    }

    func testAllowedNamesDeduplicatesOrderStable() {
        let catalog = CategoryCatalog(custom: [
            CustomCategory(name: "Finance"),   // collides with a built-in
            CustomCategory(name: "Invoices"),
            CustomCategory(name: "invoices")   // collides with the prior custom
        ])
        let names = catalog.allowedNames
        // Built-ins come first, then the single new custom name.
        XCTAssertEqual(names.prefix(CategoryCatalog.builtInNames.count).map { $0 },
                       CategoryCatalog.builtInNames)
        XCTAssertEqual(names.filter { $0.lowercased() == "invoices" }.count, 1)
        XCTAssertEqual(names.filter { $0.lowercased() == "finance" }.count, 1)
    }
}
