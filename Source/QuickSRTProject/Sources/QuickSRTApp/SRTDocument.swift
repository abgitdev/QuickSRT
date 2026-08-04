import Foundation

struct SRTCue: Equatable, Sendable {
    let index: Int
    let timingLine: String
    let text: String
}

struct SRTDocument: Equatable, Sendable {
    let cues: [SRTCue]

    init(validatedURL url: URL) throws {
        try SRTValidator.validate(url)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let contents = String(data: data, encoding: .utf8) else {
            throw QuickSRTError.invalidSRT(.invalidUTF8)
        }

        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        self.cues = try blocks.enumerated().map { offset, block in
            let lines = block.components(separatedBy: "\n")
            guard
                lines.count >= 3,
                let index = Int(lines[0].trimmingCharacters(in: .whitespaces))
            else {
                throw QuickSRTError.invalidSRT(.cueMissingText(offset + 1))
            }
            return SRTCue(
                index: index,
                timingLine: lines[1],
                text: lines.dropFirst(2).joined(separator: "\n")
            )
        }
    }

    init(cues: [SRTCue]) {
        self.cues = cues
    }

    func write(to url: URL) throws {
        let contents = cues.map { cue in
            "\(cue.index)\n\(cue.timingLine)\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
        guard let data = contents.data(using: .utf8) else {
            throw QuickSRTError.translationOutputInvalid
        }
        try data.write(to: url, options: .atomic)
        try SRTValidator.validate(url)
    }
}
