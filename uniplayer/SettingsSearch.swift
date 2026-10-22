//
//  SettingsSearch.swift
//  uniplayer
//
//  Created by Hechen Li on 2026-05-11.
//  Copyright © 2026 lhc. All rights reserved.
//

struct SettingsSearch {
  class Entry {
    let page: String
    let anchor: Int
    let title: String
    let isMain: Bool
    let extraTerms: [String] = []
    let section: String?
    let parent: Int?

    let icon: NSImage?

    var pageTitle: String?
    var parentEntry: Entry?
    var mainEntry: Entry?

    var isPageHeader: Bool {
      icon != nil
    }

    var titleForDisplay: String {
      mainEntry?.title ?? title
    }

    init(page: String, anchor: Int, title: String, isMain: Bool, section: String?, parent: Int?, icon: NSImage? = nil) {
      self.page = page
      self.anchor = anchor
      self.title = title
      self.isMain = isMain
      self.section = section
      self.parent = parent
      self.icon = icon
    }

    /// For displaying group headers in the result table
    convenience init(pageHeader header: String, icon: NSImage) {
      self.init(page: header, anchor: -1, title: "", isMain: false, section: nil, parent: nil, icon: icon)
    }

    static func assignMainAndParentEntries(_ entries: [Entry]) {
      let dict = Dictionary(grouping: entries, by: \.anchor)
      for (_, group) in dict {
        let mainEntry = group.first(where: \.isMain)
        group.filter { !$0.isMain }.forEach { $0.mainEntry = mainEntry }
      }
      for entry in entries where entry.parent != nil {
        entry.parentEntry = dict[entry.parent!]?.first(where: \.isMain)
      }
    }
  }

  struct Context {
    let page: String
    let section: String?
    let parent: Int?

    func with(section: String?) -> Self {
      .init(page: page, section: section, parent: parent)
    }

    func with(parent: Int?) -> Self {
      .init(page: page, section: section, parent: parent)
    }

    func add(_ tag: Int, _ entry: String?, isMain: Bool = false) {
      guard let entry else { return }
      entries.append(.init(page: page, anchor: tag, title: entry,
                           isMain: isMain, section: section, parent: parent))
    }
  }

  static var entries: [Entry] = []

  static private var lastString: String = ""

  static func makeTries() {
    Entry.assignMainAndParentEntries(entries)
  }

  static func search(_ searchString: String) -> [SettingsSearch.Entry]? {
    if searchString == lastString {
      return nil
    }
    lastString = searchString

    let terms = searchString.lowercased().split(whereSeparator: { $0 == " " || $0 == "　" })
    guard !terms.isEmpty else { return entries }

    return entries.filter { entry in
      let haystack = ([[entry.title], entry.extraTerms]
        .flatMap { $0 }
        .compactMap { $0 }
        .joined(separator: " "))
        .lowercased()
      return terms.allSatisfy { haystack.contains($0) }
    }
  }

  static func add(entry: SettingsSearch.Entry) {
    entries.append(entry)
  }
}

