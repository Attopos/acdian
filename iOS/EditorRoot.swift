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
        // Until a language is picked in Settings, the iPad follows the device.
        if UserDefaults.standard.string(forKey:"appLanguage") == nil { UserDefaults.standard.set(AppLanguage.forDevice.rawValue,forKey:"appLanguage") }
        DispatchQueue.global(qos:.userInitiated).async {
            let found = ReaderFiles.pagesRoot()
            DispatchQueue.main.async {
                PagesStorage.adopt(found.root)
                let model = AppModel()
                model.services.applyAppearance(model.appearance)
                self.model = model
            }
        }
    }
}

/// Sheets the workspace can show; one at a time.
enum EditorSheet: Identifiable {
    case rename(VaultEntry), move(VaultEntry), module(PageModule?), settings, cardIndex(VaultEntry)
    var id: String {
        switch self {
        case .rename(let entry): return "rename:" + entry.id
        case .move(let entry): return "move:" + entry.id
        case .module(let module): return "module:" + (module?.id ?? "+")
        case .settings: return "settings"
        case .cardIndex(let entry): return "card:" + entry.id
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
    @State private var sheet: EditorSheet?
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var searching = false
    @State private var showingOutline = false
    var body: some View {
        NavigationSplitView(columnVisibility:$columns) {
            SidebarList(model:model,sheet:$sheet,searching:$searching)
        } detail: { DetailPane(model:model,showingPhotos:$showingPhotos,showingFiles:$showingFiles,showingOutline:$showingOutline) }
        .background { shortcuts }
        .sheet(item:$sheet) { item in
            switch item {
            case .rename(let entry): RenameSheet(model:model,entry:entry)
            case .move(let entry): MoveSheet(model:model,entry:entry)
            case .module(let module): ModuleSheet(model:model,module:module)
            case .settings: SettingsSheet(model:model)
            case .cardIndex(let folder): CardIndexSheet(model:model,folder:folder)
            }
        }
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
    /// The Mac's menu shortcuts, which iPadOS also lists when ⌘ is held down.
    private var shortcuts: some View {
        Group {
            Button(model.localized("新建页面")) { model.newPageFromEditor() }.keyboardShortcut("n")
            Button(model.localized("保存页面")) { model.save() }.keyboardShortcut("s")
            Button(model.localized("关闭标签页")) { model.closeCurrentTab() }.keyboardShortcut("w")
            Button(model.localized("搜索页面")) { columns = .all; searching = true }.keyboardShortcut("f")
            Button(model.localized("插入附件…")) { model.importAttachment() }.keyboardShortcut("i",modifiers:[.command,.shift])
            Button(model.localized("显示或隐藏目录")) { showingOutline.toggle() }.keyboardShortcut("l",modifiers:[.command,.shift])
            Button(model.localized("刷新页面")) { model.refresh() }.keyboardShortcut("r")
            Button(model.localized("所有页面")) { model.goHome() }.keyboardShortcut("h",modifiers:[.command,.shift])
            Button(model.localized("显示或隐藏侧栏")) { withAnimation { columns = columns == .detailOnly ? .all : .detailOnly } }.keyboardShortcut("s",modifiers:[.control,.command])
            Button(model.localized("评论")) { EditorHost.shared.format("comment") }.keyboardShortcut("m",modifiers:[.command,.shift])
        }.opacity(0).frame(width:0,height:0).accessibilityHidden(true)
    }
    /// The editor's latest text is asked for, and written, before iOS suspends the app.
    private func saveInBackground() {
        var task = UIBackgroundTaskIdentifier.invalid
        func finish() { if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid } }
        task = UIApplication.shared.beginBackgroundTask(withName:"Save page") { finish() }
        model.withEditorSnapshot({ model.save(); model.saveSplit(); finish() },onFailure:{ model.save(); finish() })
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
            model.insertImage(data,ext:item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")
        }
        photos = []
    }
}

/// Modules at the top level, the active module's pages as a tree below, search on top.
struct SidebarList: View {
    @ObservedObject var model: AppModel
    @Binding var sheet: EditorSheet?
    @Binding var searching: Bool
    @State private var showHidden = false
    var body: some View {
        List {
            if !model.query.isEmpty {
                Section { ForEach(model.matches) { row($0) } }
            } else {
                if model.activeModule == nil {
                    Section(model.localized("模块")) {
                        ForEach(model.presentModules.filter { !$0.hidden || showHidden }) { module in
                            Button { model.enterModule(module.id) } label: {
                                Label { Text(module.name).foregroundStyle(Color.ink) } icon: { Image(systemName:ModuleStyle.symbol(module.icon)).foregroundStyle(ModuleStyle.glyph(module.color)) }
                            }
                            .opacity(module.hidden ? 0.45 : 1)
                            .contextMenu {
                                Button { sheet = .module(module) } label: { Label(model.localized("编辑模块…"),systemImage:"slider.horizontal.3") }
                                Button { model.setModuleHidden(module.id,!module.hidden) } label: { Label(module.hidden ? model.localized("取消隐藏") : model.localized("隐藏"),systemImage:module.hidden ? "eye" : "eye.slash") }
                                Button(role:.destructive) { model.removeModule(module.id) } label: { Label(model.localized("从模块中移除（保留文件夹）"),systemImage:"minus.circle") }
                            }
                        }
                        Button { sheet = .module(nil) } label: { Label(model.localized("新建模块"),systemImage:"plus") }
                        if model.presentModules.contains(where:\.hidden) {
                            Button { showHidden.toggle() } label: { Label(showHidden ? model.localized("收起已隐藏的模块") : model.localized("显示已隐藏的模块 (%@)",model.language.number(model.presentModules.filter(\.hidden).count)),systemImage:showHidden ? "eye.slash" : "eye") }.foregroundStyle(.secondary)
                        }
                    }
                }
                Section { OutlineGroup(rows,children:\.children) { entry in row(entry) } }
                Section {
                    Button { model.showTrash() } label: { Label(model.localized("垃圾桶"),systemImage:"trash") }
                    Button { sheet = .settings } label: { Label(model.localized("设置"),systemImage:"gearshape") }
                }
            }
        }
        .listStyle(.sidebar).refreshable { model.refresh() }
        .searchable(text:$model.query,isPresented:$searching,prompt:model.localized("搜索"))
        .navigationTitle(model.activeModule?.name ?? model.localized("模块"))
        .toolbar {
            ToolbarItem(placement:.topBarLeading) { if model.activeModule != nil { Button { model.enterModule(nil) } label: { Image(systemName:"square.grid.2x2") }.accessibilityIdentifier("modules") } }
            ToolbarItem(placement:.topBarTrailing) { Button { model.newPageFromEditor() } label: { Image(systemName:"square.and.pencil") }.accessibilityIdentifier("newPage") }
        }
    }
    private var rows: [VaultEntry] {
        let hidden = model.componentHiddenFolders
        func visible(_ list: [VaultEntry]) -> [VaultEntry] { list.filter { !hidden.contains($0.relativePath) } }
        return visible(model.activeModule == nil ? model.sidebarEntries.filter { !$0.isDirectory } : model.sidebarEntries)
    }
    @ViewBuilder private func row(_ entry: VaultEntry) -> some View {
        let name = entry.ext == "md" || entry.ext == ComponentStore.fileExtension ? (entry.name as NSString).deletingPathExtension : entry.name
        Button { if !entry.isDirectory { model.open(entry) } } label: {
            Label { Text(name).foregroundStyle(Color.ink) } icon: { Image(systemName:entry.isDirectory ? "folder" : entry.ext == "md" ? "doc.text" : entry.ext == ComponentStore.fileExtension ? "rectangle.grid.2x2" : "paperclip").foregroundStyle(Color.acPink) }
        }
        .accessibilityIdentifier("row-" + entry.relativePath)
        .contextMenu {
            if !entry.isDirectory, entry.ext == "md" { Button { model.openInSplit(entry) } label: { Label(model.localized("在分屏中打开"),systemImage:"rectangle.split.2x1") } }
            if entry.isDirectory { Button { sheet = .cardIndex(entry) } label: { Label(model.localized("添加 %@",model.localized("卡片索引")),systemImage:"rectangle.grid.2x2") } }
            Button { sheet = .rename(entry) } label: { Label(model.localized("重命名"),systemImage:"pencil") }
            Button { sheet = .move(entry) } label: { Label(model.localized("移动到"),systemImage:"folder") }
            Button(role:.destructive) { model.delete(entry) } label: { Label(model.localized("移到垃圾桶"),systemImage:"trash") }
        }
    }
}

struct DetailPane: View {
    @ObservedObject var model: AppModel
    @Binding var showingPhotos: Bool
    @Binding var showingFiles: Bool
    @Binding var showingOutline: Bool
    @State private var keyboardVisible = false
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                if !model.tabs.isEmpty, !model.showingTrash { TabStrip(model:model) }
                content.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.selected?.ext == "md", !model.showingTrash {
                    ToolbarItemGroup(placement:.topBarTrailing) {
                        Button { showingOutline.toggle() } label: { Image(systemName:"list.bullet.indent") }.accessibilityIdentifier("outline")
                            .popover(isPresented:$showingOutline) { OutlineList(model:model) { showingOutline = false } }
                        Menu { Button { showingPhotos = true } label: { Label(model.localized("图片"),systemImage:"photo") }; Button { showingFiles = true } label: { Label(model.localized("文件"),systemImage:"folder") } } label: { Image(systemName:"paperclip") }.accessibilityIdentifier("attach")
                    }
                }
            }
            .safeAreaInset(edge:.bottom,spacing:0) { if keyboardVisible, model.selected?.ext == "md" { FormatBar() } }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }
    @ViewBuilder private var content: some View {
        if model.showingTrash { TrashList(model:model) }
        else if let file = model.selected, file.ext == "md" {
            if let split = model.splitEntry {
                HStack(spacing:0) {
                    EditorWebView(model:model)
                    Divider()
                    VStack(spacing:0) {
                        HStack {
                            Text((split.name as NSString).deletingPathExtension).font(.footnote.weight(.medium)).lineLimit(1)
                            Spacer()
                            Button { model.closeSplit() } label: { Image(systemName:"xmark") }.accessibilityIdentifier("closeSplit")
                        }.padding(.horizontal,12).padding(.vertical,6).background(Color.wash)
                        if split.ext == "md" { EditorWebView(model:model,host:.split) } else { AttachmentPreview(file:split,model:model) }
                    }
                }.ignoresSafeArea(edges:.bottom)
            } else {
                VStack(spacing:0) {
                    if model.isDraft { DraftTitleField(model:model) }
                    EditorWebView(model:model)
                }.ignoresSafeArea(edges:.bottom)
            }
        }
        else if let file = model.selected, file.ext == ComponentStore.fileExtension { EditableCardIndex(model:model,file:file) }
        else if let file = model.selected { AttachmentPreview(file:file,model:model) }
        else if let module = model.activeModule, module.kind == .attachments { AttachmentsGrid(model:model,module:module) }
        else { ReaderEmptyState(icon:"doc.text",message:model.localized("页面")) }
    }
}

/// Open pages as tabs, restored on relaunch by the shared model, as on the Mac.
struct TabStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:4) {
                ForEach(model.tabs) { tab in
                    let active = tab.id == model.activeTabID
                    HStack(spacing:6) {
                        Text(model.tabTitle(tab)).font(.footnote.weight(active ? .semibold : .regular)).lineLimit(1)
                        Button { model.closeTab(tab.id) } label: { Image(systemName:"xmark").font(.caption2.weight(.semibold)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal,12).padding(.vertical,7)
                    .background(active ? Color.wash : .clear,in:RoundedRectangle(cornerRadius:8,style:.continuous))
                    .foregroundStyle(active ? Color.ink : .secondary)
                    .contentShape(Rectangle()).onTapGesture { model.selectTab(tab.id) }
                    .accessibilityIdentifier("tab-" + model.tabTitle(tab))
                }
            }.padding(.horizontal,10).padding(.vertical,6)
        }.background(Color.canvas)
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
                Text(model.language.remainingTrashDays(max(1,Int(ceil(entry.expiresAt.timeIntervalSinceNow / 86400))))).font(.caption).foregroundStyle(.secondary)
                Button(model.localized("恢复")) { model.restoreFromTrash(entry) }.buttonStyle(.bordered).accessibilityIdentifier("restore-" + entry.name)
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
            Form { TextField(model.localized("名称"),text:$name).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("renameField") }
                .navigationTitle(model.localized("重命名")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button(model.localized("取消")) { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button(model.localized("好")) { model.finishRenaming(entry.relativePath,to:name); dismiss() }.disabled(name.isEmpty).accessibilityIdentifier("renameDone") }
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
                    .accessibilityIdentifier("moveTo-" + folder)
            }
            .navigationTitle(model.localized("移动到")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button(model.localized("取消")) { dismiss() } } }
        }
    }
}

/// A new page's title, typed above the editor as on the Mac; the page gets its
/// file name from it once something is written.
struct DraftTitleField: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        TextField("",text:$model.draftTitle,prompt:Text("New Page").foregroundColor(Color.primary.opacity(0.25)))
            .font(.system(size:model.fontSize * 2,weight:.bold)).foregroundStyle(Color.ink)
            .focused($focused).submitLabel(.next)
            .accessibilityIdentifier("draftTitle")
            .onSubmit { focused = false; model.editorFocus?() }
            .onChange(of:focused) { _,isFocused in if !isFocused { model.draftTitleEnded() } }
            .padding(.horizontal,36).padding(.top,24).padding(.bottom,4)
            .frame(maxWidth:860,alignment:.leading).frame(maxWidth:.infinity)
            .onAppear { focused = true }
    }
}
