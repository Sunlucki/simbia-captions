import Foundation
import SimbiaCore

/// `simbia mcp`: the Model Context Protocol server Claude talks to — JSON-RPC 2.0, one message per line on
/// stdin/stdout (logs go to stderr). The tools work on a workspace: the one the server was started in (Claude Code
/// starts it in the folder its `.mcp.json` is in), or the one a tool is given. The heavy commands run this same
/// executable as a child (`simbia check …`), so the tools and the command line can never disagree.
enum MCPServer {
    static let version = "2025-06-18"

    static func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let id = message["id"], method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            guard let id else { continue }                            // notifications (initialized, cancelled) need no answer
            switch method {
            case "initialize":
                let asked = params["protocolVersion"] as? String
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": asked ?? version,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "simbia", "version": "2.0"],
                    "instructions": instructions]])
            case "ping":
                send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            case "tools/list":
                send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let (content, isError) = await call(name, arguments)
                send(["jsonrpc": "2.0", "id": id, "result": ["content": content, "isError": isError]])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no method \(method)"]])
            }
        }
    }

    static let instructions = """
    Simbia Captions edits vertical video ads; a workspace is a folder with simbia-workspace.json, its projects \
    (.simbia JSON files) and its libraries. Start with workspace_info and list_projects, and read the workspace's \
    CLAUDE.md: it holds the house rules and what to report after each task. The person may have the app open on \
    the same file: it reloads your saves live, and a save is refused when the file changed since you read it. \
    Order of work: read_project, change, save_project with `changes` in plain words (revision, author and journal \
    are handled). Captions come from the voice with captions_from_voice: pass the exact script as `script` so the \
    words are the script's and only the timing comes from the voice; it lists script words the voice doesn't say. \
    Then fix_project and check_project until it ends with OK, look with frames, and only then export_project. \
    Never rebuild a project the person has edited in the app (journal entries by app): change only what the task names.
    """

    // MARK: Tools

    static func schema(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }
    static let workspaceArg: [String: Any] = ["type": "string", "description": "a folder in the workspace; default: where the server runs"]
    static let projectArg: [String: Any] = ["type": "string", "description": "a .simbia path, a file name in the projects folder, or its start (\"VD 12\")"]

    static let tools: [[String: Any]] = [
        ["name": "workspace_info", "description": "The workspace: name, brand, dictionary, author and every folder (absolute, and whether it exists).",
         "inputSchema": schema(["workspace": workspaceArg])],
        ["name": "create_workspace", "description": "A new workspace in a folder: Projects/, Library/{Footage,Music,Reviews,Motion}/, Exports/, simbia-workspace.json, CLAUDE.md, .mcp.json.",
         "inputSchema": schema(["folder": ["type": "string"], "name": ["type": "string"], "brand": ["type": "string", "description": "the brand's name, spelt as captions must spell it"],
                                "author": ["type": "string", "description": "who edits in the app"]], required: ["folder", "name"])],
        ["name": "list_projects", "description": "Every project of the workspace, one line each: file, status (new/review/done), revision and who saved last (app = the person), length, shots, how many tasks are open (read_project shows them).",
         "inputSchema": schema(["workspace": workspaceArg])],
        ["name": "read_project", "description": "A project's whole .simbia JSON, compact (no indentation).",
         "inputSchema": schema(["project": projectArg, "workspace": workspaceArg], required: ["project"])],
        ["name": "save_project", "description": "Saves a project's whole JSON (as read_project gave it, edited). Refused when the file changed since it was read (its revision moved on). Bumps the revision, sets savedBy to claude and writes the journal line from `changes`.",
         "inputSchema": schema(["project": projectArg, "json": ["type": "string"], "changes": ["type": "array", "items": ["type": "string"], "description": "what changed, in plain words"],
                                "workspace": workspaceArg], required: ["project", "json", "changes"])],
        ["name": "create_project", "description": "A new empty project in the workspace's projects folder (1080x1920, 30 fps) to fill with save_project.",
         "inputSchema": schema(["name": ["type": "string", "description": "file name without .simbia, e.g. \"VD 12 DEMO - HOOK\""], "workspace": workspaceArg], required: ["name"])],
        ["name": "check_project", "description": "Everything that would render wrongly or read badly (missing files, captions off the voice, too fast, near a cut…). OK at the end means clean.",
         "inputSchema": schema(["project": projectArg, "workspace": workspaceArg], required: ["project"])],
        ["name": "fix_project", "description": "Fixes what check_project lists, the way the app's Fix all does (or only the kinds named), and saves.",
         "inputSchema": schema(["project": projectArg, "kinds": ["type": "array", "items": ["type": "string"], "description": "overlap, repeated, brand, voice, nearCut, gap, fast, small, shortTitle, hiddenCut"],
                                "workspace": workspaceArg], required: ["project"])],
        ["name": "frames", "description": "The finished picture at the given seconds, as images (captions and titles on, unless overlays is false).",
         "inputSchema": schema(["project": projectArg, "times": ["type": "array", "items": ["type": "number"]], "overlays": ["type": "boolean"],
                                "workspace": workspaceArg], required: ["project", "times"])],
        ["name": "export_project", "description": "Renders the finished video (picture, captions, titles, mix at -14 LUFS) into the workspace's exports folder, or to `output`. Takes about as long as the video, or longer.",
         "inputSchema": schema(["project": projectArg, "output": ["type": "string"], "workspace": workspaceArg], required: ["project"])],
        ["name": "journal", "description": "Who changed which project and what, newest first (by app = the person, by claude = Claude).",
         "inputSchema": schema(["project": ["type": "string", "description": "only this project's file name"], "limit": ["type": "integer"], "workspace": workspaceArg])],
        ["name": "suggest_footage", "description": "The footage index's best moments for what is said over a shot (needs the workspace's footage index).",
         "inputSchema": schema(["project": projectArg, "shot": ["type": "integer", "description": "the shot's place in time order, from 0"], "workspace": workspaceArg], required: ["project", "shot"])],
        ["name": "words", "description": "What the Mac hears in a video or sound file, word by word with times.",
         "inputSchema": schema(["media": ["type": "string"], "from": ["type": "number"], "to": ["type": "number"]], required: ["media"])],
        ["name": "captions_from_voice", "description": "Makes the captions from the project's voice clips (all, or those in `clips`) the way the app's «Create captions» does: the Mac's recogniser times every word and anchors it to its voice, one paragraph per clip, grouped for the caption style. With `script` the captions are exactly those words (e.g. the brief's script), timed by what is heard, and the script words the voice was not heard saying are listed. Replaces the captions over those clips (all captions when `clips` is left out) and saves: revision, journal.",
         "inputSchema": schema(["project": projectArg, "clips": ["type": "array", "items": ["type": "string"], "description": "voice clip ids, e.g. [\"a1\"]; default: every voice clip"],
                                "style": ["type": "string", "description": "caption style s1…s14 for the whole video; default: the project's"],
                                "script": ["type": "string", "description": "the exact words the captions must say, in order"],
                                "locale": ["type": "string", "description": "the voice's language, default en-US"],
                                "workspace": workspaceArg], required: ["project"])],
    ]

    typealias Content = [[String: Any]]
    static func text(_ s: String) -> Content { [["type": "text", "text": s]] }

    static func call(_ name: String, _ a: [String: Any]) async -> (Content, Bool) {
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let at = (a["workspace"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? here
        let workspace = Workspace.find(near: at)
        if let workspace { Workspace.active = workspace }
        func needWorkspace() -> Workspace? { workspace }
        func projectURL() -> URL? {
            guard let p = a["project"] as? String else { return nil }
            if let w = workspace, let url = w.project(named: p) { return url }
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let noWorkspace = (text("No \(Workspace.fileName) in \(at.path) or above. Create one with create_workspace, or pass `workspace`."), true)
        let noProject = (text("No such project: \(a["project"] as? String ?? "(none)")"), true)

        switch name {
        case "workspace_info":
            guard let w = needWorkspace() else { return noWorkspace }
            return (text(json(info(w))), false)

        case "create_workspace":
            guard let folder = a["folder"] as? String, let wname = a["name"] as? String else { return (text("folder and name are needed"), true) }
            let brandName = a["brand"] as? String ?? ""
            do {
                let w = try Workspace.create(at: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true), name: wname,
                                             brand: Brand(name: brandName, key: brandName.isEmpty ? "product" : brandName.lowercased().filter(\.isLetter)),
                                             author: a["author"] as? String, simbia: Bundle.main.executableURL?.resolvingSymlinksInPath())
                return (text("Created «\(w.settings.name)» in \(w.root.path).\n" + json(info(w))), false)
            } catch { return (text(error.localizedDescription), true) }

        case "list_projects":
            guard let w = needWorkspace() else { return noWorkspace }
            // one line each: a few hundred projects stay a few thousand tokens (the tasks themselves are in read_project)
            let lines = w.summaries().map(\.line)
            return (text("\(lines.count) projects in \(w.projects.path)\n" + lines.joined(separator: "\n")), false)

        case "read_project":
            guard let url = projectURL() else { return noProject }
            // without the file's indentation: about a third smaller, so most projects fit one tool answer
            guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data),
                  let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return (text("cannot read \(url.path)"), true) }
            return (text(String(decoding: compact, as: UTF8.self)), false)

        case "save_project":
            guard let url = projectURL() else { return noProject }
            guard let body = a["json"] as? String, var project = try? JSONDecoder().decode(Project.self, from: Data(body.utf8)) else {
                return (text("json is not a readable .simbia project"), true)
            }
            let changes = (a["changes"] as? [String] ?? []).filter { !$0.isEmpty }
            guard !changes.isEmpty else { return (text("say what changed in `changes`"), true) }
            if let disk = try? Project.load(from: url), disk.revision != project.revision {
                return (text("\(url.lastPathComponent) changed since it was read: revision \(disk.revision) by \(disk.savedBy), yours is \(project.revision). Read it again and redo the change."), true)
            }
            project.revision += 1; project.savedBy = "claude"
            do { try project.save(to: url) } catch { return (text(error.localizedDescription), true) }
            Journal.append(JournalEntry(project: url.lastPathComponent, revision: project.revision, by: "claude", changes: changes),
                           inFolder: url.deletingLastPathComponent())
            return (text("saved \(url.lastPathComponent), revision \(project.revision)"), false)

        case "create_project":
            guard let w = needWorkspace() else { return noWorkspace }
            guard let pname = a["name"] as? String, !pname.isEmpty, !pname.contains("/") else { return (text("a file name is needed"), true) }
            let url = w.projects.appending(path: pname + "." + Project.fileExtension)
            guard !FileManager.default.fileExists(atPath: url.path) else { return (text("\(url.lastPathComponent) exists already"), true) }
            var project = Project(); project.name = pname; project.savedBy = "claude"; project.revision = 1
            do { try project.save(to: url) } catch { return (text(error.localizedDescription), true) }
            Journal.append(JournalEntry(project: url.lastPathComponent, revision: 1, by: "claude", changes: ["new project"]), inFolder: w.projects)
            return (text("created \(url.path)"), false)

        case "check_project":
            guard let url = projectURL() else { return noProject }
            let r = await simbia(["check", url.path])
            return (text(r.output), false)

        case "fix_project":
            guard let url = projectURL() else { return noProject }
            let r = await simbia(["fix", url.path] + (a["kinds"] as? [String] ?? []))
            return (text(r.output), r.status != 0)

        case "frames":
            guard let url = projectURL() else { return noProject }
            let times = (a["times"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
            guard !times.isEmpty, times.count <= 8 else { return (text("1 to 8 times, in seconds"), true) }
            let dir = FileManager.default.temporaryDirectory.appending(path: "simbia-frames-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let list = times.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let r = await simbia(["frame", url.path, list, dir.appending(path: "f").path] + ((a["overlays"] as? Bool) == false ? ["--no-overlay"] : []))
            guard r.status == 0 else { return (text(r.output), true) }
            var content: Content = []
            for png in ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
            where png.pathExtension == "png" {
                let small = dir.appending(path: png.deletingPathExtension().lastPathComponent + ".jpg")
                _ = await run("/usr/bin/sips", ["-Z", "960", "-s", "format", "jpeg", png.path, "--out", small.path])
                if let data = try? Data(contentsOf: small) {
                    content.append(["type": "text", "text": png.lastPathComponent])
                    content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
                }
            }
            return (content.isEmpty ? text("no frames came out:\n" + r.output) : content, content.isEmpty)

        case "export_project":
            guard let url = projectURL() else { return noProject }
            let out = (a["output"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? (workspace?.exports ?? url.deletingLastPathComponent()).appending(path: url.deletingPathExtension().lastPathComponent + ".mp4")
            try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let r = await simbia(["export", url.path, out.path])
            return (text(r.output + (r.status == 0 ? "\n→ \(out.path)" : "")), r.status != 0)

        case "journal":
            guard let w = needWorkspace() else { return noWorkspace }
            let entries = Journal.read(inFolder: w.projects, project: a["project"] as? String, limit: (a["limit"] as? Int) ?? 30)
            let f = ISO8601DateFormatter()
            return (text(json(entries.map { ["at": f.string(from: $0.at), "project": $0.project, "revision": $0.revision, "by": $0.by, "changes": $0.changes] })), false)

        case "suggest_footage":
            guard let url = projectURL() else { return noProject }
            let r = await simbia(["suggest", url.path, String(a["shot"] as? Int ?? 0)])
            return (text(r.output), r.status != 0)

        case "words":
            guard let media = a["media"] as? String else { return (text("media is needed"), true) }
            var argv = ["words", (media as NSString).expandingTildeInPath]
            if let from = (a["from"] as? NSNumber)?.doubleValue, let to = (a["to"] as? NSNumber)?.doubleValue { argv += [String(from), String(to)] }
            let r = await simbia(argv)
            return (text(r.output), r.status != 0)

        case "captions_from_voice":
            guard let url = projectURL() else { return noProject }
            var argv = ["captions", url.path]
            for id in a["clips"] as? [String] ?? [] { argv += ["--clip", id] }
            if let style = a["style"] as? String { argv += ["--style", style] }
            if let locale = a["locale"] as? String { argv += ["--locale", locale] }
            let script = FileManager.default.temporaryDirectory.appending(path: "simbia-script-\(UUID().uuidString.prefix(8)).txt")
            defer { try? FileManager.default.removeItem(at: script) }
            if let words = a["script"] as? String {
                do { try words.write(to: script, atomically: true, encoding: .utf8) } catch { return (text(error.localizedDescription), true) }
                argv += ["--script", script.path]
            }
            let r = await simbia(argv)
            return (text(r.output), r.status != 0)

        default:
            return (text("no tool \(name)"), true)
        }
    }

    // MARK: Helpers

    static func info(_ w: Workspace) -> [String: Any] {
        let fm = FileManager.default
        func folder(_ url: URL) -> [String: Any] { ["path": url.path, "exists": fm.fileExists(atPath: url.path)] }
        return ["name": w.settings.name, "root": w.root.path, "author": w.settings.author as Any, "brand": [
                    "name": w.settings.brand.name, "key": w.settings.brand.key, "houseMusic": w.settings.brand.houseMusic as Any],
                "glossary": w.glossaryWords, "projects": w.projectFiles().count, "folders": [
                    "projects": folder(w.projects), "footage": folder(w.footage), "footageIndex": folder(w.footageIndex), "music": folder(w.music),
                    "reviews": folder(w.reviews), "motion": folder(w.motion), "exports": folder(w.exports)]]
    }

    static func json(_ value: Any) -> String {
        let clean = scrub(value)
        guard let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Optionals that are nil become JSON null.
    static func scrub(_ value: Any) -> Any {
        if let d = value as? [String: Any] { return d.mapValues(scrub) }
        if let a = value as? [Any] { return a.map(scrub) }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.map { scrub($0.value) } ?? NSNull() }
        return value
    }

    static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: scrub(message), options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    /// This same executable with `arguments`: its output and exit status.
    static func simbia(_ arguments: [String]) async -> (output: String, status: Int32) {
        guard let me = Bundle.main.executableURL else { return ("cannot find simbia", 1) }
        return await run(me.path, arguments)
    }

    static func run(_ path: String, _ arguments: [String]) async -> (output: String, status: Int32) {
        await withCheckedContinuation { done in
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: path); p.arguments = arguments
            p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { done.resume(returning: (error.localizedDescription, 1)); return }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                done.resume(returning: (String(decoding: data, as: UTF8.self), p.terminationStatus))
            }
        }
    }
}
