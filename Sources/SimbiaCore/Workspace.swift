import Foundation

/// A workspace: one brand's (or one person's) whole job in one folder — its projects, its libraries, its settings and
/// its notes for Claude — with `simbia-workspace.json` at the top. The app and `simbia` find it by walking up from a
/// project, and look every library up in it first (footage index, music, reviews, motion scenes).
///
///     simbia-workspace.json   name, author, brand, dictionary, folders (relative to this folder, or absolute)
///     CLAUDE.md               how Claude works here (written once; then it is yours to extend)
///     .mcp.json               the `simbia mcp` server, so Claude Code gets the Simbia tools in this folder
///     Projects/               the .simbia files and their _journal.jsonl
///     Library/Footage/        clips; Library/Footage/_index is the footage index, if there is one
///     Library/Music/          music beds
///     Library/Reviews/        reviews.json and the reviewers' photos in av/
///     Library/Motion/         motion scenes, each a folder of PNG frames
///     Exports/                finished videos
public struct Workspace: Equatable, Sendable {
    public static let fileName = "simbia-workspace.json"

    public struct Folders: Codable, Equatable, Sendable {
        public var projects = "Projects"
        public var footage = "Library/Footage"
        public var footageIndex = "Library/Footage/_index"
        public var music = "Library/Music"
        public var reviews = "Library/Reviews"
        public var motion = "Library/Motion"
        public var exports = "Exports"

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self), d = Folders()
            projects = try c.decodeIfPresent(String.self, forKey: .projects) ?? d.projects
            footage = try c.decodeIfPresent(String.self, forKey: .footage) ?? d.footage
            footageIndex = try c.decodeIfPresent(String.self, forKey: .footageIndex) ?? d.footageIndex
            music = try c.decodeIfPresent(String.self, forKey: .music) ?? d.music
            reviews = try c.decodeIfPresent(String.self, forKey: .reviews) ?? d.reviews
            motion = try c.decodeIfPresent(String.self, forKey: .motion) ?? d.motion
            exports = try c.decodeIfPresent(String.self, forKey: .exports) ?? d.exports
        }

        private enum CodingKeys: String, CodingKey { case projects, footage, footageIndex, music, reviews, motion, exports }
    }

    public struct Settings: Codable, Equatable, Sendable {
        public var format = "simbia-workspace"
        public var version = 1
        public var name: String
        /// Who edits in the app, as the journal and the project browser name them; nil = "You".
        public var author: String?
        public var brand = Brand()
        /// Words spelt one way in every caption, after the brand's name.
        public var glossary: [String] = []
        public var folders = Folders()

        public init(name: String, author: String? = nil, brand: Brand = Brand(), glossary: [String] = []) {
            self.name = name; self.author = author; self.brand = brand; self.glossary = glossary
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Workspace"
            author = try c.decodeIfPresent(String.self, forKey: .author)
            brand = try c.decodeIfPresent(Brand.self, forKey: .brand) ?? Brand()
            glossary = try c.decodeIfPresent([String].self, forKey: .glossary) ?? []
            folders = try c.decodeIfPresent(Folders.self, forKey: .folders) ?? Folders()
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        }

        private enum CodingKeys: String, CodingKey { case format, version, name, author, brand, glossary, folders }
    }

    public let root: URL
    public var settings: Settings

    public init(root: URL, settings: Settings) { self.root = root.standardizedFileURL; self.settings = settings }

    public var file: URL { root.appending(path: Self.fileName) }
    public func folder(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true) : root.appending(path: expanded, directoryHint: .isDirectory)
    }
    public var projects: URL { folder(settings.folders.projects) }
    public var footage: URL { folder(settings.folders.footage) }
    public var footageIndex: URL { folder(settings.folders.footageIndex) }
    public var music: URL { folder(settings.folders.music) }
    public var reviews: URL { folder(settings.folders.reviews) }
    public var motion: URL { folder(settings.folders.motion) }
    public var exports: URL { folder(settings.folders.exports) }

    /// The brand's name, then the workspace's own words, each once.
    public var glossaryWords: [String] {
        var seen = Set<String>()
        return ([settings.brand.name] + settings.glossary).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Files

    public static func load(_ root: URL) throws -> Workspace {
        let data = try Data(contentsOf: root.appending(path: fileName))
        return Workspace(root: root, settings: try JSONDecoder().decode(Settings.self, from: data))
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }

    /// The workspace `url` (a project, a clip or a folder) is in: the nearest folder above it with the settings file.
    public static func find(near url: URL?) -> Workspace? {
        guard let url else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var folder: URL? = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : url.deletingLastPathComponent()
        while let dir = folder, dir.path != "/" {
            if fm.fileExists(atPath: dir.appending(path: fileName).path), let w = try? load(dir) { return w }
            folder = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// A new workspace in `root` (made if missing): its folders, its settings, CLAUDE.md and — given the `simbia`
    /// executable — .mcp.json. Files already there are left alone; a folder that is already a workspace is refused.
    @discardableResult
    public static func create(at root: URL, name: String, brand: Brand = Brand(), author: String? = nil, simbia: URL? = nil) throws -> Workspace {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appending(path: fileName).path) else {
            throw NSError(domain: "simbia", code: 10, userInfo: [NSLocalizedDescriptionKey: "\(root.path) is a workspace already"])
        }
        let w = Workspace(root: root, settings: Settings(name: name, author: author, brand: brand))
        for dir in [w.projects, w.footage, w.music, w.reviews, w.motion, w.exports] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try w.save()
        let notes = root.appending(path: "CLAUDE.md")
        if !fm.fileExists(atPath: notes.path) { try claudeNotes(w).write(to: notes, atomically: true, encoding: .utf8) }
        if let simbia { try w.writeMCPConfig(simbia: simbia) }
        return w
    }

    /// `.mcp.json` with the `simbia` server, unless the folder has one already (then only reported).
    @discardableResult
    public func writeMCPConfig(simbia: URL) throws -> Bool {
        let url = root.appending(path: ".mcp.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        let config: [String: Any] = ["mcpServers": ["simbia": ["type": "stdio", "command": simbia.path, "args": ["mcp"]]]]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url)
        return true
    }

    // MARK: The open one

    private static let lock = NSLock()
    nonisolated(unsafe) private static var opened: Workspace?

    /// The workspace of the open project (the app) or of the project a command works on (`simbia`).
    public static var active: Workspace? {
        get { lock.lock(); defer { lock.unlock() }; return opened }
        set { lock.lock(); opened = newValue; lock.unlock() }
    }

    /// Makes the workspace around `url` the active one; outside any, the active one is left as it is.
    @discardableResult
    public static func activate(near url: URL?) -> Workspace? {
        guard let w = find(near: url) else { return nil }
        active = w
        return w
    }

    // MARK: CLAUDE.md

    static func claudeNotes(_ w: Workspace) -> String {
        let f = w.settings.folders
        return """
        # \(w.settings.name) — a Simbia workspace

        This folder is a Simbia Captions workspace: vertical video ads edited in the Simbia app, with Claude working
        on the same files. `simbia-workspace.json` holds the name, the brand, the dictionary and where everything is.

        ## Folders

        | Folder | What is in it |
        |---|---|
        | `\(f.projects)/` | the projects (`*.simbia`, JSON) and `_journal.jsonl`, who changed what |
        | `\(f.footage)/` | the clips to edit with; `\(f.footageIndex)/` is the footage index, if there is one |
        | `\(f.music)/` | music beds |
        | `\(f.reviews)/` | `reviews.json` and the reviewers' photos in `av/` |
        | `\(f.motion)/` | motion scenes: one folder of PNG frames (30 fps, with alpha) per scene |
        | `\(f.exports)/` | finished videos |

        ## Tools

        Claude Code gets the Simbia tools from `.mcp.json` (the `simbia mcp` server): workspace info, the list of
        projects, reading and saving a project, checks and fixes, frames to look at, export, the journal.
        The same engine is a command line tool, `simbia` (run `simbia` with no arguments for its commands).

        ## Working on a project

        - A `.simbia` file is the whole edit as JSON: `shots`, `audio`, `overlays`, `captions`, `titles`, `tasks`,
          `brief`, `status`. Times are seconds on the edit's clock; paths are absolute or relative to the project file.
        - The app keeps an open project in sync with its file both ways: what you save appears in the editor at once.
        - Every save: `revision` + 1 and `savedBy: "claude"`, and a line in `\(f.projects)/_journal.jsonl`
          (`{"at", "project", "revision", "by": "claude", "changes": [...]}`) saying in plain words what changed.
          The `save_project` tool does all three.
        - `savedBy: "app"` means the person edited it in the app: read it again before you change anything, and
          never undo their edits.
        - Check before you hand anything over: `check_project` (or `simbia check`) must say OK; look at frames
          (`frames`) and listen to the loudness numbers the export prints.
        - Finished videos go to `\(f.exports)/`.

        ## This workspace's own rules

        Add here what Claude must know about this brand and this work: the client, the style, what to avoid.

        """
    }
}

// MARK: - Projects of a workspace

/// One project as a list shows it.
public struct ProjectSummary: Codable, Sendable {
    public var file: String
    public var path: String
    public var name: String
    /// The first number in the file's name ("VD 436 …" → 436).
    public var number: Int?
    public var status: String
    public var revision: Int
    public var savedBy: String
    public var duration: Double
    public var shots: Int
    public var openTasks: [String]

    /// One line for a list: file, status, revision and who saved, length, shots, how many tasks are open.
    public var line: String {
        "\(file)\t\(status)\trev \(revision) \(savedBy)\t\(String(format: "%.1f", duration)) s\t\(shots) shots\t\(openTasks.count) open"
    }
}

extension Workspace {
    /// The `.simbia` files at the top of the projects folder, by name.
    public func projectFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == Project.fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func summaries() -> [ProjectSummary] {
        projectFiles().compactMap { url in
            guard let p = try? Project.load(from: url) else { return nil }
            let file = url.lastPathComponent
            let number = file.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
            return ProjectSummary(file: file, path: url.path, name: p.name, number: number, status: ProjectStatus(p.status).rawValue,
                                  revision: p.revision, savedBy: p.savedBy, duration: p.duration, shots: p.shots.count,
                                  openTasks: (p.tasks ?? []).filter { !$0.done }.map(\.text))
        }
    }

    /// A project named the way a person would: a path, a file name in the projects folder (".simbia" optional),
    /// or the start of one ("VD 12").
    public func project(named name: String) -> URL? {
        let fm = FileManager.default
        let expanded = (name as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return fm.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil }
        for candidate in [projects.appending(path: expanded), projects.appending(path: expanded + "." + Project.fileExtension)]
        where fm.fileExists(atPath: candidate.path) { return candidate }
        let files = projectFiles()
        return files.first { $0.deletingPathExtension().lastPathComponent == name }
            ?? files.first { $0.lastPathComponent.hasPrefix(name + " ") }
    }
}
