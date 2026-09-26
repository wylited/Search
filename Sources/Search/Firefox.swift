import Foundation
import SQLite3

// Reading what Zen — or plain Firefox — already holds on this Mac.
//
// The shape of it is the Chromium import next door, asked of a browser that
// keeps things its own way. Three differences are worth knowing before the
// code below.
//
// Its history and its bookmarks come out of one SQLite file, places.sqlite,
// copied before it is read for the same reason the Chromium files are: the
// browser it belongs to is usually running, and the last few minutes of what
// happened are in the write-ahead log beside it.
//
// Its bookmarks are rows rather than a JSON document, filed under four roots
// the table that once named them (moz_bookmarks_roots) stopped naming years
// ago. What is left is the guid written on each root row, which is what every
// version since writes and what this file reads.
//
// The tabs open this minute are in sessionstore-backups, in Mozilla's own
// wrapper around LZ4: eight bytes of magic, four of size, then the block. That
// arithmetic is fifty lines below rather than a dependency, which is the only
// kind this app has.
//
// Passwords are not read here at all: they are moving to Bitwarden rather than
// into this app's keychain, so logins.json and key4.db are left untouched and
// this import never has to explain a keychain refusal.

enum Firefox {
    /// One profile of one of the two browsers, and where the things worth
    /// bringing over sit inside it.
    struct Source: Identifiable, Hashable {
        /// "Zen" or "Firefox", as the window should name it.
        let name: String
        /// The profile folder itself, under ~/Library/Application Support.
        let profile: URL

        var id: String { profile.path }

        var places: URL { profile.appendingPathComponent("places.sqlite") }
        var icons: URL { profile.appendingPathComponent("favicons.sqlite") }
        var sessions: URL { profile.appendingPathComponent("sessionstore-backups", isDirectory: true) }
    }

    enum Trouble: Error {
        case unreadable
    }

    /// The two browsers, in the order a Mac with both should offer them: Zen
    /// first, since a profile of the fork is the reason to be here at all,
    /// then Firefox itself for anyone who never installed one.
    private static let homes: [(name: String, folder: String)] = [
        ("Zen", "zen"),
        ("Firefox", "Firefox"),
    ]

    /// Every profile on this Mac with a places.sqlite in it to read.
    static func installed() -> [Source] {
        homes.flatMap { home in
            profiles(of: home.folder).map { Source(name: home.name, profile: $0) }
        }
        .filter { FileManager.default.fileExists(atPath: $0.places.path) }
    }

    /// The profiles inside one browser's folder: profiles.ini first, which is
    /// the list the browser itself keeps, then any folder beside it the file
    /// does not mention — a profile made by a tool that never updated the
    /// file is still a profile with things in it.
    private static func profiles(of folder: String) -> [URL] {
        let home = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
        var out: [URL] = []
        var seen = Set<String>()

        // A relative path is relative to the folder profiles.ini sits in,
        // which is how every profile on a Mac is written — the profile this
        // was built for has a space and parentheses in its name, and is
        // written there like any other.
        for path in iniPaths(at: home.appendingPathComponent("profiles.ini")) {
            let profile = path.hasPrefix("/")
                ? URL(fileURLWithPath: path, isDirectory: true)
                : home.appendingPathComponent(path, isDirectory: true)
            guard seen.insert(profile.standardizedFileURL.path).inserted else { continue }
            out.append(profile)
        }

        let beside = home.appendingPathComponent("Profiles", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: beside, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for profile in folders where seen.insert(profile.standardizedFileURL.path).inserted {
            out.append(profile)
        }
        return out
    }

    /// Every `Path=` in a profiles.ini, in the order the file lists them. The
    /// file is a dozen lines the browser itself writes, so it is read as lines
    /// rather than with a parser for the whole of a format this is all of.
    private static func iniPaths(at file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Path=") else { return nil }
            let path = String(line.dropFirst("Path=".count)).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
    }

    // MARK: - the copy

    /// A database file copied somewhere nothing is writing to it, with the two
    /// siblings a write-ahead log keeps beside it: the log is where the last
    /// few minutes of history actually are, and a copy of the file alone is a
    /// copy of however long ago the browser last folded the log back in.
    ///
    /// The folder goes when the copy does, so nothing is left behind in /tmp.
    private final class Copy {
        let file: URL
        private let folder: URL

        init?(_ original: URL) {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("office-import-\(UUID().uuidString)", isDirectory: true)
            self.folder = folder
            let file = folder.appendingPathComponent(original.lastPathComponent)
            self.file = file
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                  (try? FileManager.default.copyItem(at: original, to: file)) != nil
            else {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            for suffix in ["-wal", "-shm"] {
                let beside = URL(fileURLWithPath: original.path + suffix)
                guard FileManager.default.fileExists(atPath: beside.path) else { continue }
                try? FileManager.default.copyItem(at: beside, to: URL(fileURLWithPath: file.path + suffix))
            }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    /// One copy, open read-only. Everything read here is SQLite, so the file
    /// this is handed is the only thing that differs between the questions.
    private static func connect(_ copy: Copy) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// A question put to an open copy, or nil for a file that hasn't got the
    /// table being asked about — an older or newer browser is a browser with
    /// no answer to this one, not an error worth raising.
    private static func query(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    // MARK: - where they have been

    struct Place {
        let url: URL
        let title: String
        let count: Int
        let last: Date
    }

    /// The other browser's history, newest first, which is what it takes for
    /// the address field to already know where you go on the first day.
    static func places(in source: Source, limit: Int = 3000) -> [Place] {
        guard let copy = Copy(source.places), let db = connect(copy) else { return [] }
        defer { sqlite3_close(db) }
        return placeRows(db, limit: limit)
    }

    /// Hidden places are the ones a browser keeps for itself — its own pages,
    /// its own redirects — and a place with no visit behind it was only ever
    /// a bookmark or a guess, both of which come over as themselves.
    private static func placeRows(_ db: OpaquePointer, limit: Int) -> [Place] {
        let sql = """
        SELECT url, title, visit_count, last_visit_date FROM moz_places
        WHERE hidden = 0 AND visit_count > 0 AND url LIKE 'http%'
        ORDER BY last_visit_date DESC LIMIT \(limit)
        """
        guard let statement = query(db, sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var out: [Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: raw)),
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            // Microseconds since 1970, which is Mozilla's idea of a date: its
            // own, and not the 1601 that Chromium counts from.
            let stamp = sqlite3_column_int64(statement, 3)
            let last = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000) : Date()
            out.append(Place(url: url, title: title, count: max(1, count), last: last))
        }
        return out
    }

    // MARK: - what they kept

    /// The other browser's bookmarks, in the shape the bookmark menu already
    /// understands: the toolbar's pages at the top level, where the Chromium
    /// import puts its bookmarks bar, and each of the other piles in a folder
    /// under the name Firefox itself gives it.
    static func bookmarks(in source: Source) -> [Bookmark] {
        guard let copy = Copy(source.places), let db = connect(copy) else { return [] }
        defer { sqlite3_close(db) }
        return bookmarkNodes(db)
    }

    /// The four piles worth bringing over, and the name each one's children
    /// are filed under when it is not the bar itself. The tree's own root is
    /// not among them — the other four are inside it — and neither is the tags
    /// pile, which holds labels rather than bookmarks.
    private static let roots: [(guid: String, name: String?)] = [
        ("toolbar_____", nil),
        ("unfiled_____", "Other Bookmarks"),
        ("menu________", "Bookmarks Menu"),
        ("mobile______", "Mobile Bookmarks"),
    ]

    private struct Row {
        let id: Int64
        let folder: Bool
        let title: String
        let url: String?
    }

    /// The whole tree out of one question. A profile's bookmarks number in the
    /// hundreds, and asking the file once per folder would be one question per
    /// folder; the join is there so a bookmark arrives with its address, which
    /// is the one thing the bookmark table itself doesn't keep.
    private static func bookmarkNodes(_ db: OpaquePointer) -> [Bookmark] {
        let sql = """
        SELECT b.id, b.type, b.parent, b.title, b.guid, p.url
        FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk
        ORDER BY b.parent, b.position
        """
        guard let statement = query(db, sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var children: [Int64: [Row]] = [:]
        var begins: [String: Int64] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let type = Int(sqlite3_column_int(statement, 1))
            let parent = sqlite3_column_int64(statement, 2)
            let title = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let guid = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let url = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            // Folders and bookmarks, and the guids of the four that have one:
            // a separator and a tag are rows too, and neither is a bookmark.
            if let root = roots.first(where: { $0.guid == guid }) {
                begins[root.guid] = id
            }
            guard type == 1 || type == 2 else { continue }
            children[parent, default: []].append(Row(id: id, folder: type == 2, title: title, url: url))
        }

        var out: [Bookmark] = []
        for root in roots {
            guard let id = begins[root.guid] else { continue }
            let kids = nodes(of: id, in: children)
            guard !kids.isEmpty else { continue }
            if let name = root.name {
                out.append(.folder(name, kids))
            } else {
                out += kids
            }
        }
        return out
    }

    /// One pile, folders opened: a folder becomes a folder, a bookmark a page.
    /// Anything that is not a page is dropped rather than brought over as
    /// something the window could not open — the browser's own "Most Visited"
    /// and "Recent Tags" rows are `place:` addresses like any other.
    private static func nodes(of parent: Int64, in children: [Int64: [Row]]) -> [Bookmark] {
        (children[parent] ?? []).compactMap { row in
            if row.folder { return .folder(row.title, nodes(of: row.id, in: children)) }
            guard let url = row.url.flatMap(URL.init(string:)),
                  url.scheme == "http" || url.scheme == "https"
            else { return nil }
            return .site(row.title, url)
        }
    }

    /// Every page in a tree, folders opened: the walk `Bookmarks.urls` makes,
    /// without hopping to the main actor to make it — this one runs on the
    /// queue that read the tree in the first place.
    static func pages(in nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return pages(in: node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    // MARK: - what they have open

    /// A tab the other browser has open right now.
    struct Open {
        let url: URL
        let title: String
        /// Its pinned tabs, which this browser keeps too.
        let pinned: Bool
    }

    /// The tabs open this minute, every window's, in the order the windows
    /// keep them. The newest of the three files the browser leaves behind is
    /// the one taken, and it is copied before it is read for the same reason
    /// the database is: the browser writing it is usually still running, and
    /// this file is rewritten every few seconds while it is.
    static func tabs(in source: Source) -> [Open] {
        for name in ["recovery.jsonlz4", "recovery.baklz4", "previous.jsonlz4"] {
            let file = source.sessions.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path),
                  let copy = Copy(file),
                  let data = try? Data(contentsOf: copy.file),
                  let raw = unwrap(data),
                  let top = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            else { continue }
            return openTabs(in: top)
        }
        return []
    }

    /// The entry each tab is on, which is what `index` counts to from one. A
    /// tab whose index doesn't land in its own list — a file written in the
    /// middle of a navigation — is taken at its last entry, which is where a
    /// tab that is going somewhere has gone. Two tabs on one address come over
    /// as one: this browser's row is a row of pages, not a record of how many
    /// times a page was opened.
    private static func openTabs(in top: [String: Any]) -> [Open] {
        var out: [Open] = []
        var seen = Set<String>()
        for window in top["windows"] as? [[String: Any]] ?? [] {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                let entries = tab["entries"] as? [[String: Any]] ?? []
                let index = (tab["index"] as? Int ?? entries.count) - 1
                let entry = entries.indices.contains(index) ? entries[index] : entries.last
                guard let entry,
                      let text = entry["url"] as? String,
                      let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https",
                      seen.insert(url.absoluteString).inserted
                else { continue }
                out.append(Open(
                    url: url,
                    title: entry["title"] as? String ?? "",
                    pinned: tab["pinned"] as? Bool ?? false
                ))
            }
        }
        return out
    }

    /// A session file is the magic "mozLz40\0", the size of what is inside as
    /// four little-endian bytes, and then an LZ4 block — the frame format in
    /// name only, and the reason this file carries its own decompressor rather
    /// than a dependency to do fifty lines of arithmetic.
    private static func unwrap(_ data: Data) -> Data? {
        let head = [UInt8](data.prefix(12))
        guard head.count == 12, head.prefix(8).elementsEqual(Array("mozLz40\u{0}".utf8)) else { return nil }
        let size = Int(head[8]) | Int(head[9]) << 8 | Int(head[10]) << 16 | Int(head[11]) << 24
        return lz4([UInt8](data.dropFirst(12)), size: size)
    }

    /// LZ4's block format: a token whose high four bits are how many bytes
    /// follow as they are, a two-byte distance back to what they copy, and the
    /// low four bits plus four as the copy's length. A count that doesn't fit
    /// in four bits carries extra bytes, 255 at a time, until one that isn't.
    /// The last sequence of a block is its literals and nothing else, so the
    /// loop ends at the end of the input.
    private static func lz4(_ input: [UInt8], size: Int) -> Data? {
        // The size in the header is what the block is going to be, and the
        // only bound worth having: LZ4 expands by 255 times at most, so a size
        // beyond that is a damaged header rather than a large session, and it
        // is not going to be believed into an allocation.
        var bound = input.count * 255
        if size > 0 { bound = min(bound, size) }

        var out = [UInt8]()
        out.reserveCapacity(bound)
        var i = 0
        while i < input.count {
            let token = Int(input[i])
            i += 1
            var literals = token >> 4
            if literals == 15 {
                while i < input.count {
                    let more = Int(input[i])
                    i += 1
                    literals += more
                    if more != 255 { break }
                }
            }
            guard i + literals <= input.count, out.count + literals <= bound else { return nil }
            out.append(contentsOf: input[i ..< i + literals])
            i += literals
            guard i < input.count else { break }
            guard i + 2 <= input.count else { return nil }
            let back = Int(input[i]) | Int(input[i + 1]) << 8
            i += 2
            guard back > 0, back <= out.count else { return nil }
            var length = (token & 15) + 4
            if token & 15 == 15 {
                while i < input.count {
                    let more = Int(input[i])
                    i += 1
                    length += more
                    if more != 255 { break }
                }
            }
            guard out.count + length <= bound else { return nil }
            // A byte at a time, because a run may copy what it is writing:
            // that is how LZ4 spells a page of one repeated character.
            let start = out.count - back
            for step in 0 ..< length {
                out.append(out[start + step])
            }
        }
        return Data(out)
    }

    // MARK: - the icons they had

    /// The other browser's icons for the given pages, host by host: the
    /// largest bitmap it kept for the page itself, or failing that for the
    /// site's front door. Firefox keeps them in a database of their own beside
    /// the history, which is copied and read the same way.
    static func icons(in source: Source, for urls: [URL], limit: Int = 400) -> [String: Data] {
        var wanted: [(host: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let host = url.host()?.lowercased(), seen.insert(host).inserted else { continue }
            wanted.append((host, url))
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty, FileManager.default.fileExists(atPath: source.icons.path),
              let copy = Copy(source.icons), let db = connect(copy)
        else { return [:] }
        defer { sqlite3_close(db) }

        // Every address worth asking about at once. The pages table is the
        // biggest in this file and has no index on the address itself, so a
        // question per address would be a scan of that table per address —
        // two addresses a host, hundreds of hosts. One question covers them.
        var doors: [String: (host: String, own: Bool)] = [:]
        for (host, url) in wanted {
            doors[url.absoluteString] = (host, true)
            if let scheme = url.scheme, let name = url.host() {
                let front = "\(scheme)://\(name)/"
                if doors[front] == nil { doors[front] = (host, false) }
            }
        }
        let names = Array(doors.keys)
        let sql = """
        SELECT p.page_url, i.width, i.data
        FROM moz_pages_w_icons p
        JOIN moz_icons_to_pages m ON m.page_id = p.id
        JOIN moz_icons i ON i.id = m.icon_id
        WHERE p.page_url IN (\(Array(repeating: "?", count: names.count).joined(separator: ",")))
        AND i.width BETWEEN 16 AND 256
        """
        guard let statement = query(db, sql) else { return [:] }
        defer { sqlite3_finalize(statement) }
        for (at, name) in names.enumerated() {
            sqlite3_bind_text(statement, Int32(at + 1), name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        var best: [String: (own: Bool, width: Int, image: Data)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0),
                  let bytes = sqlite3_column_blob(statement, 2),
                  let door = doors[String(cString: raw)]
            else { continue }
            let width = Int(sqlite3_column_int(statement, 1))
            let count = Int(sqlite3_column_bytes(statement, 2))
            // Under sixty bytes is a colour or a stub, not a picture.
            guard count > 60 else { continue }
            let found = (own: door.own, width: width, image: Data(bytes: bytes, count: count))
            guard let keep = best[door.host] else {
                best[door.host] = found
                continue
            }
            // The page's own icon beats its front door's, and a bigger one
            // beats a smaller: the same rule the Chromium import follows.
            if found.own == keep.own {
                if found.width > keep.width { best[door.host] = found }
            } else if found.own {
                best[door.host] = found
            }
        }
        return best.mapValues { $0.image }
    }

    // MARK: - one pass over a profile

    /// What one profile had, its three questions answered at once.
    struct Found {
        var places: [Place] = []
        var bookmarks: [Bookmark] = []
        var tabs: [Open] = []
    }

    /// The three things a run is worth, read out of one copy of the profile's
    /// database rather than one copy each. Throws only when nothing at all
    /// could be read: a profile that gave up everything it had, even when that
    /// was nothing, is not an error.
    static func read(
        _ source: Source,
        history: Bool = true,
        bookmarks: Bool = true,
        tabs: Bool = true,
        limit: Int = 3000
    ) throws -> Found {
        var found = Found()
        var readAny = false
        let asked = history || bookmarks || tabs

        if history || bookmarks, let copy = Copy(source.places), let db = connect(copy) {
            defer { sqlite3_close(db) }
            if history { found.places = placeRows(db, limit: limit) }
            if bookmarks { found.bookmarks = bookmarkNodes(db) }
            readAny = true
        }
        if tabs {
            found.tabs = Firefox.tabs(in: source)
            readAny = readAny || !found.tabs.isEmpty
        }
        // A caller that asked for nothing has nothing to be told about: this
        // is the one case where coming back empty is not a failure to read.
        guard readAny || !asked else { throw Trouble.unreadable }
        return found
    }

    /// What one run brought over, for the line the window puts up afterwards.
    /// A count of zero is an answer, not a failure: a profile with no
    /// bookmarks in it has no bookmarks in it.
    struct Report {
        let name: String
        let places: Int
        let bookmarks: Int
        let tabs: Int

        /// "2900 places · 12 bookmarks · 38 tabs from Zen", for whoever has
        /// nothing better to put on screen.
        var line: String {
            let parts = [
                places > 0 ? "\(places) places" : nil,
                bookmarks > 0 ? "\(bookmarks) bookmarks" : nil,
                tabs > 0 ? "\(tabs) tabs" : nil,
            ].compactMap { $0 }
            return parts.isEmpty
                ? "Nothing in \(name) to bring"
                : parts.joined(separator: " · ") + " from \(name)"
        }
    }
}

// MARK: - filing it in the list

extension Bookmarks {
    /// The other browser's bookmarks, folders and all, in one folder of its
    /// name — the folder a previous import of the same browser left, replaced
    /// rather than added to, so running this twice leaves the same list as
    /// running it once.
    ///
    /// `take` is how another browser's list comes in, and it has two rules:
    /// a list arriving at an empty top level becomes the top level, and a list
    /// arriving beside anything else is filed in a folder of that browser's
    /// name, replacing the one already there. The first rule is what an import
    /// run twice would come undone by — the first run's pages stay bare at the
    /// top, and the second run has no folder of its own to replace them from,
    /// so it files every one of them again beside them. Handing `take` a list
    /// that is already in that folder lands both rules in the same shape, and
    /// in one write: a second run of the same import is a folder replaced, not
    /// a page added.
    func shelve(_ tree: [Bookmark], as name: String) {
        guard !tree.isEmpty else { return }
        take(roots.isEmpty ? [.folder(name, tree)] : tree, from: name)
    }
}

// MARK: - bringing it in

extension Browser {
    /// The other browser's bookmarks, folders and all, behind the bookmark
    /// button — and behind them the icons it had for those sites, so the menu
    /// wears them from the start instead of a letter each.
    ///
    /// Off the main thread, unlike the Chromium import next door: the file
    /// this reads is a database of tens of megabytes, and copying that in the
    /// middle of a click is a stutter. `done` gets how many pages came over.
    func takeBookmarks(from source: Firefox.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Firefox.bookmarks(in: source)
            let icons = Firefox.icons(in: source, for: Firefox.pages(in: found))
            DispatchQueue.main.async {
                self.bookmarks.shelve(found, as: source.name)
                let count = Bookmarks.count(found)
                self.announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)")
                if !icons.isEmpty {
                    Task {
                        for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                        self.objectWillChange.send()
                    }
                }
                done(count)
            }
        }
    }

    /// Everything at once: the three questions asked in one pass over the
    /// profile, off the main thread, and written in a moment on it. The three
    /// flags are the three things a row in Settings can offer to bring; `done`
    /// gets what actually came over, one count each, for the line the window
    /// puts up afterwards — nothing is announced here, because the caller is
    /// the one that knows how to say it.
    func importFirefox(
        from source: Firefox.Source,
        history wanted: Bool = true,
        bookmarks saved: Bool = true,
        tabs open: Bool = true,
        then done: @escaping (Firefox.Report) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try Firefox.read(source, history: wanted, bookmarks: saved, tabs: open)
            }
            var icons: [String: Data] = [:]
            if case .success(let found) = outcome, saved {
                icons = Firefox.icons(in: source, for: Firefox.pages(in: found.bookmarks))
            }
            DispatchQueue.main.async {
                guard case .success(let found) = outcome else {
                    // Nothing came out of the profile at all: its database is
                    // not a database, or the profile has gone since it was
                    // listed. There is no keychain here to have been refused.
                    self.announce("Nothing readable in \(source.name)")
                    done(Firefox.Report(name: source.name, places: 0, bookmarks: 0, tabs: 0))
                    return
                }
                if wanted {
                    for place in found.places {
                        self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                    }
                    self.history.settle()
                }
                if saved { self.bookmarks.shelve(found.bookmarks, as: source.name) }
                let added = open ? self.restore(found.tabs) : 0
                if !icons.isEmpty {
                    Task {
                        for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                        self.objectWillChange.send()
                    }
                }
                done(Firefox.Report(
                    name: source.name,
                    places: wanted ? found.places.count : 0,
                    bookmarks: saved ? Bookmarks.count(found.bookmarks) : 0,
                    tabs: added
                ))
            }
        }
    }

    /// Tabs the other browser has open, put into this one's row the way this
    /// app restores its own session: an address and a name, and no page
    /// fetched until one is looked at. Thirty-nine tabs that each started
    /// loading would be thirty-nine web views and a stalled window; these cost
    /// nothing until they are asked for. Its pinned tabs stay pinned, letters
    /// and all, at the head of the row where pins live. Returns how many were
    /// added — one already open here, address for address, is not added again.
    private func restore(_ list: [Firefox.Open]) -> Int {
        var here = Set(tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
        var added = 0
        for page in list where here.insert(page.url.absoluteString).inserted {
            let tab = Tab()
            prepare(tab)
            tab.restore(url: page.url, title: page.title)
            if page.pinned {
                tab.pin = tab.monogram
                insert(tab, at: pinnedCount)
            } else {
                insert(tab, at: tabs.count)
            }
            added += 1
        }
        return added
    }
}
