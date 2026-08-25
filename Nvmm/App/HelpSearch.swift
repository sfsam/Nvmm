//
//  Nvmm
//  HelpSearch.swift
//
//  Supplies Neovim's bundled help tags to the native Help menu search field.
//

import AppKit
import Foundation

/// One entry from a Neovim `doc/tags` file.
nonisolated struct HelpTopic: Sendable, Equatable {
    let tag: String
    let file: String
    let searchKey: String

    init(tag: String, file: String) {
        self.tag = tag
        self.file = file
        searchKey = tag.lowercased()
    }
}

/// The immutable, searchable part of a Neovim help tags file.
nonisolated struct HelpTopicIndex: Sendable {
    let topics: [HelpTopic]

    init(contents: String) {
        topics = contents.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2,
                                    omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty,
                  !fields[1].isEmpty else { return nil }
            return HelpTopic(tag: String(fields[0]), file: String(fields[1]))
        }
    }

    /// Finds tags containing every whitespace-delimited query term. A full
    /// tag match sorts first; the tags file's stable order resolves the rest.
    func search(_ query: String, limit: Int) -> [HelpTopic] {
        let queryKey = query.lowercased()
        let terms = queryKey.split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty, limit > 0 else { return [] }

        let exactIndex = topics.firstIndex { $0.searchKey == queryKey }
        var matches: [HelpTopic] = []
        if let exactIndex { matches.append(topics[exactIndex]) }
        if matches.count == limit { return matches }

        for (index, topic) in topics.enumerated() {
            if index == exactIndex { continue }
            guard terms.allSatisfy(topic.searchKey.contains) else { continue }
            matches.append(topic)
            if matches.count == limit { break }
        }
        return matches
    }
}

/// The opaque object AppKit carries from a Help-menu result to its action.
private nonisolated final class HelpSearchItem: NSObject {
    let topic: HelpTopic

    init(_ topic: HelpTopic) {
        self.topic = topic
    }
}

/// Bridges the native Help menu search field to the bundled help tag index.
/// AppKit may call the search methods away from the main thread.
nonisolated final class HelpSearchController: NSObject,
                                              NSUserInterfaceItemSearching {
    private let tagsURL: URL
    private let indexLock = NSLock()
    private var cachedIndex: HelpTopicIndex?
    private let openTopic: @MainActor @Sendable (String) -> Void

    init(tagsURL: URL,
         openTopic: @escaping @MainActor @Sendable (String) -> Void) {
        self.tagsURL = tagsURL
        self.openTopic = openTopic
    }

    func searchForItems(withSearch searchString: String, resultLimit: Int,
                        matchedItemHandler handleMatchedItems:
                        @escaping ([Any]) -> Void) {
        let matches = index().search(searchString, limit: resultLimit)
        handleMatchedItems(matches.map(HelpSearchItem.init))
    }

    func localizedTitles(forItem item: Any) -> [String] {
        guard let item = item as? HelpSearchItem else { return [] }
        return [item.topic.file, item.topic.tag]
    }

    func performAction(forItem item: Any) {
        guard let item = item as? HelpSearchItem else { return }
        let topic = item.topic.tag
        Task { @MainActor [openTopic] in openTopic(topic) }
    }

    private func index() -> HelpTopicIndex {
        indexLock.lock()
        defer { indexLock.unlock() }
        if let cachedIndex { return cachedIndex }

        let contents = (try? String(contentsOf: tagsURL, encoding: .utf8)) ?? ""
        let index = HelpTopicIndex(contents: contents)
        cachedIndex = index
        return index
    }
}
