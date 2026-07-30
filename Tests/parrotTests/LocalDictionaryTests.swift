import XCTest
@testable import parrot

final class LocalDictionaryTests: XCTestCase {
    func testCanonicalizesVariantsWithoutChangingLongerWords() {
        let dictionary = LocalDictionary(entries: [
            .init(canonical: "AcmeAPI", variants: ["acme api", "acme A.P.I."]),
            .init(canonical: "ExampleDB", variants: ["example db"]),
        ])

        XCTAssertEqual(
            dictionary.apply(to: "acme api et EXAMPLE DB, mais acme apis reste inchangé."),
            "AcmeAPI et ExampleDB, mais acme apis reste inchangé."
        )
    }

    func testAddingCorrectionReplacesAnExistingConflictingVariant() {
        let dictionary = LocalDictionary(entries: [
            .init(canonical: "Old spelling", variants: ["parrot word"]),
            .init(canonical: "AcmeAPI", variants: ["acme api"]),
        ])

        let updated = dictionary.addingCorrection(
            transcribedAs: "parrot word",
            correctSpelling: "Preferred spelling"
        )

        XCTAssertEqual(
            updated.apply(to: "PARROT WORD puis acme api"),
            "Preferred spelling puis AcmeAPI"
        )
        XCTAssertEqual(
            updated.entries.first(where: { $0.canonical == "Old spelling" })?.variants,
            []
        )
    }

    func testCanonicalSpellingIsUsedLiterallyAsReplacementText() {
        let dictionary = LocalDictionary(entries: [
            .init(canonical: "C$", variants: ["c dollar"]),
        ])

        XCTAssertEqual(dictionary.apply(to: "c dollar"), "C$")
    }
}
