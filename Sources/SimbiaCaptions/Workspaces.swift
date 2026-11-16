import AppKit
import SimbiaCore
import SwiftUI

// Workspaces in the app: the one in use decides where the start screen and the project browser look, where a new
// video's project is saved, and which brand, dictionary and libraries the editor uses (SimbiaCore/Workspace.swift).

extension Job {
    /// Workspaces opened before, newest first (kept between launches).
    var recentWorkspaces: [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentWorkspaces") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: Workspace.fileName).path) }
    }

    /// `w` becomes the workspace in use: the start screen, the browser, new projects, the brand and dictionary follow.
    func useWorkspace(_ w: Workspace?) {
        guard w?.root != workspace?.root || w?.settings != workspace?.settings else { return }
        workspace = w
        Workspace.active = w
        if let w {
            var paths = UserDefaults.standard.stringArray(forKey: "recentWorkspaces") ?? []
            paths.removeAll { $0 == w.root.path }
            paths.insert(w.root.path, at: 0)
            UserDefaults.standard.set(Array(paths.prefix(10)), forKey: "recentWorkspaces")
        }
        glossary = Glossary.load()
        footage = nil; footageState = .idle
        reviews = nil
    }

    /// At launch: the workspace used last, else the one around the last project.
    func restoreWorkspace() {
        guard workspace == nil else { return }
        let w = recentWorkspaces.lazy.compactMap { try? Workspace.load($0) }.first ?? Workspace.find(near: recentProjects.first)
        useWorkspace(w)
    }

    func workspacePicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = t("Папка рабочего пространства (в ней simbia-workspace.json)", "The workspace folder (it holds simbia-workspace.json)",
                          "Le dossier de l’espace de travail (il contient simbia-workspace.json)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let w = Workspace.find(near: url) { useWorkspace(w) } else {
            show(t("Это не рабочее пространство — создайте его кнопкой «Новое пространство»", "Not a workspace — make one with New Workspace",
                   "Ce n’est pas un espace de travail — créez-en un avec Nouvel espace"), isError: true)
        }
    }

    /// The `simbia` tool Claude runs as the workspace's MCP server: inside the app, else beside it (Portable/bin).
    var simbiaTool: URL? {
        if let inside = Bundle.main.url(forAuxiliaryExecutable: "simbia") { return inside }
        let beside = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "bin/simbia")
        return FileManager.default.isExecutableFile(atPath: beside.path) ? beside : nil
    }

    func createWorkspace(in parent: URL, name: String, brand: String, author: String) {
        let folder = parent.appending(path: name.trimmingCharacters(in: .whitespaces), directoryHint: .isDirectory)
        let key = brand.lowercased().filter { $0.isLetter || $0.isNumber }
        do {
            let w = try Workspace.create(at: folder, name: name, brand: Brand(name: brand, key: key.isEmpty ? "product" : key),
                                         author: author.isEmpty ? nil : author, simbia: simbiaTool)
            useWorkspace(w)
            show(t("Пространство «\(name)» создано: \(folder.path)", "Workspace “\(name)” created: \(folder.path)",
                   "Espace « \(name) » créé : \(folder.path)"), isError: false)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    /// Who the journal names for edits made here.
    var authorName: String { workspace?.settings.author ?? t("Вы", "You", "Vous") }
}

/// The start screen's header: the workspace in use, the others, a new one.
struct WorkspaceMenu: View {
    @ObservedObject var job: Job

    var body: some View {
        Menu {
            ForEach(job.recentWorkspaces, id: \.self) { url in
                Button {
                    if let w = try? Workspace.load(url) { job.useWorkspace(w) }
                } label: {
                    let name = (try? Workspace.load(url))?.settings.name ?? url.lastPathComponent
                    if url.standardizedFileURL == job.workspace?.root { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            if !job.recentWorkspaces.isEmpty { Divider() }
            Button(job.t("Новое пространство…", "New Workspace…", "Nouvel espace…")) { job.newWorkspaceOpen = true }
            Button(job.t("Открыть пространство…", "Open Workspace…", "Ouvrir un espace…")) { job.workspacePicker() }
            if let w = job.workspace {
                Divider()
                Button(job.t("Показать в Finder", "Show in Finder", "Afficher dans le Finder")) { NSWorkspace.shared.activateFileViewerSelecting([w.file]) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 12))
                Text(job.workspace?.settings.name.uppercased() ?? job.t("БЕЗ ПРОСТРАНСТВА", "NO WORKSPACE", "AUCUN ESPACE"))
                    .font(.system(size: 13, weight: .semibold)).tracking(1.2)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(job.t("Рабочее пространство: проекты, библиотеки, бренд и заметки для Claude", "Workspace: projects, libraries, brand and notes for Claude",
                    "Espace de travail : projets, bibliothèques, marque et notes pour Claude"))
    }
}

/// A new workspace: its name, the brand, who edits, where.
struct NewWorkspaceSheet: View {
    @ObservedObject var job: Job
    @Binding var open: Bool
    @State private var name = ""
    @State private var brand = ""
    @State private var author = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    @State private var parent = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job.t("Новое рабочее пространство", "New workspace", "Nouvel espace de travail")).font(.system(size: 18, weight: .bold))
            Text(job.t("Папка с проектами, библиотеками (футаж, музыка, отзывы, моушн), экспортом и заметками для Claude.",
                       "A folder with projects, libraries (footage, music, reviews, motion), exports and notes for Claude.",
                       "Un dossier avec projets, bibliothèques (rushes, musique, avis, motion), exports et notes pour Claude."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(job.t("Название", "Name", "Nom"), text: $name)
                TextField(job.t("Бренд (как писать в субтитрах)", "Brand (as captions spell it)", "Marque (telle que l’écrivent les sous-titres)"), text: $brand)
                TextField(job.t("Ваше имя (для журнала правок)", "Your name (for the edit journal)", "Votre nom (pour le journal)"), text: $author)
                HStack {
                    Text(parent.appending(path: name.isEmpty ? "…" : name).path).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button(job.t("Где…", "Where…", "Où…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        panel.directoryURL = parent
                        if panel.runModal() == .OK, let url = panel.url { parent = url }
                    }
                }
            }
            HStack {
                Spacer()
                Button(job.t("Отмена", "Cancel", "Annuler")) { open = false }.keyboardShortcut(.cancelAction)
                Button(job.t("Создать", "Create", "Créer")) {
                    job.createWorkspace(in: parent, name: name, brand: brand, author: author)
                    open = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
