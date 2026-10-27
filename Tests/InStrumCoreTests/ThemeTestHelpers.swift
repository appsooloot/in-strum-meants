import XCTest
@testable import InStrumCore

/// Checks a theme's declared settings: unique ids, valid defaults, at least one hero.
func assertValidParameters(_ specs: [ParamSpec], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Set(specs.map(\.id)).count, specs.count, "duplicate ids", file: file, line: line)
    XCTAssertTrue(specs.contains { $0.hero }, "no hero settings", file: file, line: line)
    for s in specs {
        XCTAssertEqual(s.validated(s.defaultValue), s.defaultValue, "invalid default for \(s.id)", file: file, line: line)
        if let r = s.surprise, let range = s.range {
            XCTAssertTrue(range.contains(r.lowerBound) && range.contains(r.upperBound), "surprise outside range: \(s.id)", file: file, line: line)
        }
    }
}
