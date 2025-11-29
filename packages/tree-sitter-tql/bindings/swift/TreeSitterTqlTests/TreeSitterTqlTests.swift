import XCTest
import SwiftTreeSitter
import TreeSitterTql

final class TreeSitterTqlTests: XCTestCase {
    func testCanLoadGrammar() throws {
        let parser = Parser()
        let language = Language(language: tree_sitter_tql())
        XCTAssertNoThrow(try parser.setLanguage(language),
                         "Error loading Tql grammar")
    }
}
