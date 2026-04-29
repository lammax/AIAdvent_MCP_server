import Foundation

public protocol RAGChunker: Sendable {
    func makeChunks(from documents: [RAGSourceDocument]) -> [RAGChunk]
}

private struct RAGToken {
    let range: Range<String.Index>
}

private struct RAGTokenizer {
    private let maxTokenCharacters = 400

    func tokenize(_ text: String) -> [RAGToken] {
        var tokens: [RAGToken] = []
        var tokenStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                if let start = tokenStart {
                    appendTokens(in: start..<index, text: text, to: &tokens)
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }

            index = text.index(after: index)
        }

        if let start = tokenStart {
            appendTokens(in: start..<text.endIndex, text: text, to: &tokens)
        }

        return tokens
    }

    private func appendTokens(
        in range: Range<String.Index>,
        text: String,
        to tokens: inout [RAGToken]
    ) {
        var start = range.lowerBound

        while start < range.upperBound {
            let end = text.index(
                start,
                offsetBy: maxTokenCharacters,
                limitedBy: range.upperBound
            ) ?? range.upperBound

            tokens.append(RAGToken(range: start..<end))
            start = end
        }
    }
}

public struct FixedTokenChunker: RAGChunker {
    public let chunkSize: Int
    public let overlap: Int
    public let maxCharacters: Int

    private let tokenizer = RAGTokenizer()

    public init(chunkSize: Int = 500, overlap: Int = 50, maxCharacters: Int = 1_200) {
        self.chunkSize = max(1, chunkSize)
        self.overlap = max(0, min(overlap, max(0, chunkSize - 1)))
        self.maxCharacters = max(1, maxCharacters)
    }

    public func makeChunks(from documents: [RAGSourceDocument]) -> [RAGChunk] {
        documents.flatMap { document in
            makeChunks(
                from: document,
                section: document.title,
                strategy: .fixedTokens,
                initialChunkId: 0
            )
        }
    }

    func makeChunks(
        from document: RAGSourceDocument,
        section: String,
        strategy: RAGChunkingStrategy,
        initialChunkId: Int
    ) -> [RAGChunk] {
        let tokens = tokenizer.tokenize(document.content)
        guard !tokens.isEmpty else { return [] }

        var chunks: [RAGChunk] = []
        var start = 0
        var chunkId = initialChunkId

        while start < tokens.count {
            let end = chunkEnd(start: start, tokens: tokens, content: document.content)
            let startIndex = tokens[start].range.lowerBound
            let endIndex = tokens[end - 1].range.upperBound
            let content = String(document.content[startIndex..<endIndex])

            chunks.append(
                RAGChunk(
                    source: document.url.path,
                    title: document.title,
                    section: section,
                    chunkId: chunkId,
                    strategy: strategy,
                    content: content,
                    tokenCount: end - start,
                    startOffset: document.content.distance(from: document.content.startIndex, to: startIndex),
                    endOffset: document.content.distance(from: document.content.startIndex, to: endIndex)
                )
            )

            chunkId += 1
            if end == tokens.count {
                break
            }

            start = max(start + 1, end - overlap)
        }

        return chunks
    }

    private func chunkEnd(start: Int, tokens: [RAGToken], content: String) -> Int {
        let tokenLimit = min(start + chunkSize, tokens.count)
        var end = start + 1

        while end < tokenLimit {
            let startIndex = tokens[start].range.lowerBound
            let nextEndIndex = tokens[end].range.upperBound
            let characterCount = content.distance(from: startIndex, to: nextEndIndex)

            if characterCount > maxCharacters {
                break
            }

            end += 1
        }

        return end
    }
}

public struct StructureChunker: RAGChunker {
    private let fallback: FixedTokenChunker

    public init(chunkSize: Int = 500, overlap: Int = 50, maxCharacters: Int = 1_200) {
        self.fallback = FixedTokenChunker(
            chunkSize: chunkSize,
            overlap: overlap,
            maxCharacters: maxCharacters
        )
    }

    public func makeChunks(from documents: [RAGSourceDocument]) -> [RAGChunk] {
        documents.flatMap { document in
            switch document.url.pathExtension.lowercased() {
            case "md":
                return makeMarkdownChunks(document)
            case "swift":
                return makeSwiftChunks(document)
            default:
                return fallback.makeChunks(from: [document])
                    .map { chunk in
                        RAGChunk(
                            id: chunk.id,
                            source: chunk.source,
                            title: chunk.title,
                            section: chunk.section,
                            chunkId: chunk.chunkId,
                            strategy: .structure,
                            content: chunk.content,
                            tokenCount: chunk.tokenCount,
                            startOffset: chunk.startOffset,
                            endOffset: chunk.endOffset
                        )
                    }
            }
        }
    }

    private func makeMarkdownChunks(_ document: RAGSourceDocument) -> [RAGChunk] {
        let lines = document.content.components(separatedBy: .newlines)
        let sections = makeSections(
            document: document,
            lines: lines,
            marker: { line in line.trimmingCharacters(in: .whitespaces).hasPrefix("#") },
            title: { line in line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        )

        return makeChunks(from: document, sections: sections)
    }

    private func makeSwiftChunks(_ document: RAGSourceDocument) -> [RAGChunk] {
        let markers = ["struct ", "class ", "enum ", "extension ", "func "]
        let lines = document.content.components(separatedBy: .newlines)
        let sections = makeSections(
            document: document,
            lines: lines,
            marker: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return markers.contains { trimmed.hasPrefix($0) }
            },
            title: { line in line.trimmingCharacters(in: .whitespaces) }
        )

        return makeChunks(from: document, sections: sections)
    }

    private func makeSections(
        document: RAGSourceDocument,
        lines: [String],
        marker: (String) -> Bool,
        title: (String) -> String
    ) -> [(title: String, text: String)] {
        var sections: [(title: String, text: String)] = []
        var currentTitle = document.title
        var buffer: [String] = []

        for line in lines {
            if marker(line), !buffer.isEmpty {
                sections.append((currentTitle, buffer.joined(separator: "\n")))
                buffer.removeAll()
                currentTitle = title(line)
            } else if marker(line) {
                currentTitle = title(line)
            }

            buffer.append(line)
        }

        if !buffer.isEmpty {
            sections.append((currentTitle, buffer.joined(separator: "\n")))
        }

        return sections
    }

    private func makeChunks(
        from document: RAGSourceDocument,
        sections: [(title: String, text: String)]
    ) -> [RAGChunk] {
        var chunks: [RAGChunk] = []
        var nextChunkId = 0

        for section in sections {
            let sectionDocument = RAGSourceDocument(
                url: document.url,
                title: document.title,
                content: section.text
            )
            let sectionChunks = fallback.makeChunks(
                from: sectionDocument,
                section: section.title,
                strategy: .structure,
                initialChunkId: nextChunkId
            )

            chunks.append(contentsOf: sectionChunks)
            nextChunkId += sectionChunks.count
        }

        return chunks
    }
}
