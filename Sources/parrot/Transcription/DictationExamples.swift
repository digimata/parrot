import Foundation

/// Sentences in the user's own words, one set per language, handed to Whisper
/// before it decodes. Whisper conditions on this the way it conditions on the
/// previous window of a long recording, so the file holds *examples of speech*
/// rather than a description of the speaker.
///
/// Two measurements shape the format. An example beats a description by a wide
/// margin: "Sou desenvolvedor e falo de pull requests" recovered 62% of
/// technical terms where "Preciso revisar os pull requests antes do merge"
/// recovered 85%. And the example must match the language being spoken — a
/// Portuguese example over English audio scored 25% word accuracy against 96%
/// with none at all, because the prompt drags the decoder into its own
/// language. Hence sections rather than one blob.
struct DictationExamples {
    static let file = ModelWeights.root.appending(path: "dictation-examples.txt")

    /// Keyed by the language subtag of its `[..]` header. Text written before
    /// any header lands under `nil` and is used when nothing else matches.
    private let sections: [String?: String]

    var isEmpty: Bool { sections.isEmpty }

    init(contentsOf url: URL = DictationExamples.file) {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var sections: [String?: [String]] = [:]
        var current: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = Self.subtag(of: String(line.dropFirst().dropLast()))
                continue
            }
            sections[current, default: []].append(line)
        }
        self.sections = sections.mapValues { $0.joined(separator: " ") }
    }

    /// The example to use for a language, falling back to whatever was written
    /// before the first header. `pt-BR` and `pt` are the same section.
    func example(for language: String) -> String? {
        sections[Self.subtag(of: language)] ?? sections[nil]
    }

    /// The only language the user wrote an example for, when there is exactly
    /// one. Nothing to detect in that case, which is most people.
    var soleLanguage: String? {
        let tagged = sections.keys.compactMap { $0 }
        return tagged.count == 1 && sections[nil] == nil ? tagged[0] : nil
    }

    /// Languages are matched on the primary subtag: a user writing `[pt-BR]`
    /// and a decoder reporting `pt` mean the same thing.
    private static func subtag(of language: String) -> String {
        language.lowercased().split(separator: "-").first.map(String.init) ?? language.lowercased()
    }

    static let template = """
        # One sentence per language, the way you actually dictate, using the
        # words you want spelled correctly. The model reads this as speech that
        # came just before yours, so an example works and a description does not:
        #
        #   this works    I need to review the pull requests before the merge.
        #   this doesn't  I am a developer and I use technical terms.
        #
        # An ordinary sentence is the whole of it. Measured across eleven
        # recordings: none to one sentence was worth +36 points of
        # technical-term recall at no cost in latency, a second sentence bought
        # nothing and cost 150 ms, and packing eight terms into the sentence
        # scored the same as two. Those same eight terms written as a bare list
        # scored what no example scores. The grammar works, not the words.
        #
        # Keep languages under their own heading. An example in the wrong
        # language is worse than none: the prompt pulls the decoder along with
        # it, and English audio under a Portuguese example comes back translated.

        [en]
        I need to review the pull requests before the merge.

        [pt-BR]
        Preciso revisar os pull requests antes do merge.

        """

    /// Created on first open so the format is explained where it is edited.
    static func ensureFileExists() throws {
        let path = file.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try template.write(to: file, atomically: true, encoding: .utf8)
    }
}
