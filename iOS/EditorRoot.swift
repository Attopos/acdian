import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The iPad app: the editing counterpart of the iPhone's read-only reader.
struct EditorRoot: View {
    @StateObject private var holder = ModelHolder()
    var body: some View {
        Group {
            if let model = holder.model { EditorWorkspace(model:model,services:model.services as! IOSPlatformServices) }
            else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas) }
        }.tint(.acPink).task { holder.start() }
    }
}

/// Finds the pages location first, because the model reads the saved one when it starts.
@MainActor final class ModelHolder: ObservableObject {
    @Published var model: AppModel?
    func start() {
        guard model == nil else { return }
        DispatchQueue.global(qos:.userInitiated).async {
            let found = ReaderFiles.pagesRoot()
            DispatchQueue.main.async {
                PagesStorage.adopt(found.root)
                self.model = AppModel()
            }
        }
    }
}

struct EditorWorkspace: View {
    @ObservedObject var model: AppModel
    @ObservedObject var services: IOSPlatformServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var photos: [PhotosPickerItem] = []
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var renaming: VaultEntry?
    @State private var moving: VaultEntry?
    var body: some View {
        NavigationSplitView {
            SidebarList(model:model,renaming:$renaming,moving:$moving)
                .navigationTitle(model.activeModule?.name ?? model.localized("模块"))
                .toolbar {
                    ToolbarItem(placement:.topBarLeading) { if model.activeModule != nil { Button { model.enterModule(nil) } label: { Image(systemName:"square.grid.2x2") } } }
                    ToolbarItem(placement:.topBarTrailing) {
                        Button { model.newPageFromEditor() } label: { Image(systemName:"square.and.pencil") }.keyboardShortcut("n",modifiers:.command)
                    }
                }
        } detail: { DetailPane(model:model,showingPhotos:$showingPhotos,showingFiles:$showingFiles) }
        .sheet(item:$renaming) { RenameSheet(model:model,entry:$0) }
        .sheet(item:$moving) { MoveSheet(model:model,entry:$0) }
        .photosPicker(isPresented:$showingPhotos,selection:$photos,matching:.images)
        .onChange(of:photos) { _,items in Task { await importPhotos(items) } }
        .fileImporter(isPresented:$showingFiles,allowedContentTypes:[.item],allowsMultipleSelection:true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onChange(of:services.pickRequest != nil) { _,asked in
            guard asked, let request = services.pickRequest else { return }
            services.pickRequest = nil
            if request.imagesOnly { showingPhotos = true } else { showingFiles = true }
        }
        .alert(services.confirmation?.title ?? "",isPresented:Binding(get:{ services.confirmation != nil },set:{ if !$0 { services.confirmation = nil } })) {
            if let ask = services.confirmation {
                Button(ask.action) { ask.answer(true); services.confirmation = nil }
                Button(ask.cancel,role:.cancel) { ask.answer(false); services.confirmation = nil }
            }
        } message: { Text(services.confirmation?.detail ?? "") }
        .alert(model.localized("好"),isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) { Button(model.localized("好"),role:.cancel) {} } message: { Text(model.error ?? "") }
        .onChange(of:scenePhase) { _,phase in
            if phase == .background { saveInBackground() }
            if phase == .active { model.refresh() }
        }
    }
    /// The editor's latest text is asked for, and written, before iOS suspends the app.
    private func saveInBackground() {
        var task = UIBackgroundTaskIdentifier.invalid
        func finish() { if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid } }
        task = UIApplication.shared.beginBackgroundTask(withName:"Save page") { finish() }
        model.withEditorSnapshot({ model.save(); finish() },onFailure:{ model.save(); finish() })
    }
    private func importFiles(_ urls: [URL]) {
        // Files from another app stay readable only while their scope is open.
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        model.insertAttachments(urls)
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
    }
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            guard let data = try? await item.loadTransferable(type:Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            model.insertImage(data,ext:ext)
        }
        photos = []
    }
}

/// The active module's pages as a tree, or the module grid at the top level.
struct SidebarList: View {
    @ObservedObject var model: AppModel
    @Binding var renaming: VaultEntry?
    @Binding var moving: VaultEntry?
    var body: some View {
        List {
            if model.activeModule == nil {
                Section { ForEach(model.presentModules.filter { !$0.hidden }) { module in
                    Button { model.enterModule(module.id) } label: { Label { Text(module.name).foregroundStyle(Color.ink) } icon: { Image(systemName:ModuleStyle.symbol(module.icon)).foregroundStyle(ModuleStyle.glyph(module.color)) } }
                } }
            }
            Section { OutlineGroup(rows,children:\.children) { entry in row(entry) } }
            Section { Button { model.showTrash() } label: { Label(model.localized("垃圾桶"),systemImage:"trash") } }
        }.listStyle(.sidebar).refreshable { model.refresh() }
    }
    private var rows: [VaultEntry] {
        let hidden = model.componentHiddenFolders
        func visible(_ list: [VaultEntry]) -> [VaultEntry] { list.filter { !hidden.contains($0.relativePath) } }
        return visible(model.activeModule == nil ? model.sidebarEntries.filter { !$0.isDirectory } : model.sidebarEntries)
    }
    @ViewBuilder private func row(_ entry: VaultEntry) -> some View {
        let name = entry.ext == "md" ? String(entry.name.dropLast(3)) : entry.name
        Button { if !entry.isDirectory { model.open(entry) } } label: {
            Label { Text(name).foregroundStyle(Color.ink) } icon: { Image(systemName:entry.isDirectory ? "folder" : entry.ext == "md" ? "doc.text" : "paperclip").foregroundStyle(Color.acPink) }
        }
        .contextMenu {
            Button { renaming = entry } label: { Label(model.localized("重命名"),systemImage:"pencil") }
            Button { moving = entry } label: { Label(model.localized("移动到"),systemImage:"folder") }
            Button(role:.destructive) { model.delete(entry) } label: { Label(model.localized("移到垃圾桶"),systemImage:"trash") }
        }
    }
}

struct DetailPane: View {
    @ObservedObject var model: AppModel
    @Binding var showingPhotos: Bool
    @Binding var showingFiles: Bool
    @ObservedObject private var host = EditorHost.shared
    @State private var keyboardVisible = false
    var body: some View {
        NavigationStack {
            Group {
                if model.showingTrash { TrashList(model:model) }
                else if let file = model.selected, file.ext == "md" { EditorWebView(model:model).ignoresSafeArea(edges:.bottom) }
                else if let file = model.selected { AttachmentPreview(file:file,model:model) }
                else { ReaderEmptyState(icon:"doc.text",message:model.localized("页面")) }
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.selected?.ext == "md", !model.showingTrash {
                    ToolbarItemGroup(placement:.topBarTrailing) {
                        Button { model.save() } label: { Image(systemName:"checkmark.circle") }.keyboardShortcut("s",modifiers:.command)
                        Menu { Button { showingPhotos = true } label: { Label(model.localized("图片"),systemImage:"photo") }; Button { showingFiles = true } label: { Label(model.localized("文件"),systemImage:"folder") } } label: { Image(systemName:"paperclip") }.accessibilityIdentifier("attach")
                    }
                }
            }
            .safeAreaInset(edge:.bottom,spacing:0) { if keyboardVisible, model.selected?.ext == "md" { FormatBar() } }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }
}

/// Formatting buttons above the keyboard, instead of the Mac's floating toolbar,
/// which would collide with the system's own edit menu.
struct FormatBar: View {
    private let actions: [(String,String)] = [("bold","bold"),("italic","italic"),("strike","strikethrough"),("code","chevron.left.forwardslash.chevron.right"),("h1","textformat.size"),("bullet","list.bullet"),("todo","checklist"),("quote","text.quote"),("comment","text.bubble"),("undo","arrow.uturn.backward"),("redo","arrow.uturn.forward")]
    var body: some View {
        HStack(spacing:4) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:2) {
                    ForEach(actions,id:\.0) { action,symbol in
                        Button { EditorHost.shared.format(action) } label: { Image(systemName:symbol).frame(width:40,height:36) }.buttonStyle(.plain).foregroundStyle(Color.ink).accessibilityIdentifier("format-\(action)")
                    }
                }
            }
            Button { EditorHost.shared.dismissKeyboard() } label: { Image(systemName:"keyboard.chevron.compact.down").frame(width:40,height:36) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(.horizontal,8).padding(.vertical,4).background(.bar)
    }
}

struct AttachmentPreview: View {
    let file: VaultEntry
    @ObservedObject var model: AppModel
    @State private var data: Data?
    var body: some View {
        Group {
            if let data, file.ext == "pdf" { PDFScreen(data:data).ignoresSafeArea(edges:.bottom) }
            else if let data, MediaKinds.images.contains(file.ext) { ImageScreen(data:data) }
            else if data != nil { ReaderEmptyState(icon:"doc",message:file.name) }
            else { ProgressView() }
        }.task(id:file.id) { data = try? await ReaderFiles.data(file.url) }
    }
}

struct TrashList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        List(model.trashEntries) { entry in
            HStack {
                VStack(alignment:.leading) { Text(entry.name).foregroundStyle(Color.ink); Text(entry.originalRelativePath).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                Button(model.localized("恢复")) { model.restoreFromTrash(entry) }.buttonStyle(.bordered)
            }
        }.overlay { if model.trashEntries.isEmpty { ReaderEmptyState(icon:"trash",message:model.localized("垃圾桶")) } }
    }
}

struct RenameSheet: View {
    @ObservedObject var model: AppModel
    let entry: VaultEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form { TextField(model.localized("名称"),text:$name).autocorrectionDisabled().textInputAutocapitalization(.never) }
                .navigationTitle(model.localized("重命名")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button(model.localized("取消")) { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button(model.localized("好")) { model.finishRenaming(entry.relativePath,to:name); dismiss() }.disabled(name.isEmpty) }
                }
        }.onAppear { name = entry.ext == "md" ? String(entry.name.dropLast(3)) : entry.name; model.renamingPath = entry.relativePath }
    }
}

struct MoveSheet: View {
    @ObservedObject var model: AppModel
    let entry: VaultEntry
    @Environment(\.dismiss) private var dismiss
    private var folders: [String] {
        var list = [""]
        func walk(_ entries: [VaultEntry]) { for item in entries where item.isDirectory && item.relativePath != entry.relativePath { list.append(item.relativePath); walk(item.children ?? []) } }
        walk(model.index?.entries ?? [])
        return list
    }
    var body: some View {
        NavigationStack {
            List(folders,id:\.self) { folder in
                Button { model.movePage(entry.relativePath,to:PageDropTarget(folder:folder)); dismiss() } label: { Label(folder.isEmpty ? model.localized("顶层") : folder,systemImage:"folder").foregroundStyle(Color.ink) }
            }
            .navigationTitle(model.localized("移动到")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button(model.localized("取消")) { dismiss() } } }
        }
    }
}
