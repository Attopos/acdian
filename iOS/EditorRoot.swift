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
                PerfLog.mark("iPad pages root \(found.root.path) (iCloud \(found.iCloud))")
                if found.iCloud { ICloudDownloader.start(root:found.root) {
                    PerfLog.mark("iPad shows \(model.index?.files.count ?? 0) files, modules: \(model.presentModules.map(\.name))")
                    model.refresh()
                } }
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
                        let shown = model.presentModules.filter { !$0.hidden || showHidden }
                        ForEach(shown) { module in
                            Button { model.enterModule(module.id) } label: {
                                Label { Text(module.name).foregroundStyle(Color.ink) } icon: { Image(systemName:ModuleStyle.symbol(module.icon)).foregroundStyle(ModuleStyle.glyph(module.color)) }
                            }
                            .opacity(module.hidden ? 0.45 : 1)
                            .contextMenu {
                                Button { sheet = .module(module) } label: { Label(model.localized("编辑模块…"),systemImage:"slider.horizontal.3") }
                                Button { model.setModuleHidden(module.id,!module.hidden) } label: { Label(module.hidden ? model.localized("取消隐藏") : model.localized("隐藏"),systemImage:module.hidden ? "eye" : "eye.slash") }
                                Button(role:.destructive) { model.removeModule(module.id) } label: { Label(model.localized("从模块中移除（保留文件夹）"),systemImage:"minus.circle") }
                            }
                            .accessibilityIdentifier("module-" + module.folder)
                        }
                        // Dragging a module reorders the launcher, as on the Mac.
                        .onMove { from,to in
                            guard let index = from.first else { return }
                            model.moveModule(shown[index].id,before:to < shown.count ? shown[to].id : "")
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
    @State private var shareURL: URL?
    @ObservedObject private var host = EditorHost.shared
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
        .confirmationDialog("",isPresented:Binding(get:{ host.imageMenu != nil },set:{ if !$0 { host.imageMenu = nil } })) {
            if let menu = host.imageMenu, let url = model.index?.resolve(menu.target,from:menu.page) {
                Button(model.localized("拷贝图片")) { model.copyImage(menu.target,from:menu.page) }
                Button(model.localized("分享…")) { shareURL = url }
                Button(model.localized("在“文件”中显示")) { if let files = URL(string:"shareddocuments://" + url.path.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)!) { UIApplication.shared.open(files) } }
            }
        }
        .sheet(item:Binding(get:{ shareURL.map(SharedFile.init) },set:{ shareURL = $0?.url })) { ShareSheet(url:$0.url) }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }
    @ViewBuilder private var content: some View {
        if model.showingTrash { TrashList(model:model) }
        else if let file = model.selected, file.ext == "md" {
            if let split = model.splitEntry {
                SplitPanes(model:model,split:split).ignoresSafeArea(edges:.bottom)
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
            Button { EditorHost.shared.dismissKeyboard() } label: { Image(systemName:"keyboard.chevron.compact.down").frame(width:40,height:36) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("hideKeyboard")
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
        .toolbar {
            if !model.trashEntries.isEmpty {
                ToolbarItem(placement:.primaryAction) {
                    Button(role:.destructive) { model.confirmEmptyTrash() } label: { Text(model.localized("清空垃圾桶")) }.accessibilityIdentifier("emptyTrash")
                }
            }
        }
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

/// The open page and a second one side by side. The divider can be dragged
/// (double-tap to centre it), and the sides swapped, as on the Mac.
struct SplitPanes: View {
    @ObservedObject var model: AppModel
    let split: VaultEntry
    @State private var dragStart: CGFloat?
    var body: some View {
        GeometryReader { geometry in
            // The panes keep their places in the view tree and only change sides,
            // so their web views are never torn down by a swap.
            let width = geometry.size.width, divider = max(200,min(width - 200,width * model.splitFraction))
            HStack(spacing:0) {
                EditorWebView(model:model).environment(\.layoutDirection,.leftToRight)
                    .frame(width:model.splitOnLeft ? width - divider - 14 : divider)
                handle(width:width,divider:divider)
                splitPane.environment(\.layoutDirection,.leftToRight)
            }
            .environment(\.layoutDirection,model.splitOnLeft ? .rightToLeft : .leftToRight)
        }
    }
    private func handle(width: CGFloat, divider: CGFloat) -> some View {
        ZStack { Rectangle().fill(Color.faint).frame(width:1); Capsule().fill(Color.secondary.opacity(0.5)).frame(width:4,height:40) }
            .frame(width:14).frame(maxHeight:.infinity).contentShape(Rectangle())
            // Measured in the window, because the divider itself moves while it is dragged.
            .gesture(DragGesture(minimumDistance:2,coordinateSpace:.global).onChanged { drag in
                let origin = dragStart ?? divider; dragStart = origin
                model.splitFraction = min(max((origin + drag.translation.width) / width,0.2),0.8)
            }.onEnded { _ in dragStart = nil })
            .onTapGesture(count:2) { model.splitFraction = 0.5 }
            .accessibilityIdentifier("splitDivider")
    }
    private var splitPane: some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                Text((split.name as NSString).deletingPathExtension).font(.footnote.weight(.medium)).lineLimit(1)
                Spacer()
                Button { model.swapSplitSides() } label: { Image(systemName:"arrow.left.arrow.right") }.accessibilityIdentifier("swapSplit")
                Button { model.closeSplit() } label: { Image(systemName:"xmark") }.accessibilityIdentifier("closeSplit")
            }.padding(.horizontal,12).padding(.vertical,6).background(Color.wash)
            if split.ext == "md" { EditorWebView(model:model,host:.split) } else { AttachmentPreview(file:split,model:model) }
        }
    }
}

struct SharedFile: Identifiable { let url: URL; var id: String { url.path } }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Brings every page in the iCloud folder onto the iPad. iOS keeps pages it has
/// not been asked for as placeholders, which the editor's listing cannot use, so
/// all of them are requested, and the pages list is refreshed as they arrive.
enum ICloudDownloader {
    static func start(root: URL, refresh: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos:.utility).async {
            var last = -1, quiet = 0
            // Keep asking until nothing is left or nothing has changed for a few minutes.
            while quiet < 60 {
                let waiting = requestMissing(root:root)
                PerfLog.mark("iCloud pages still downloading: \(waiting)")
                if waiting != last { last = waiting; quiet = 0; DispatchQueue.main.async { refresh() } } else { quiet += 1 }
                if waiting == 0 { return }
                Thread.sleep(forTimeInterval:5)
            }
        }
    }
    /// Asks for every placeholder under the root and returns how many there are.
    private static func requestMissing(root: URL) -> Int {
        let manager = FileManager.default
        guard let walk = manager.enumerator(at:root,includingPropertiesForKeys:[.ubiquitousItemDownloadingStatusKey],options:[],errorHandler:{ _,_ in true }) else { return 0 }
        var waiting = 0, seen = 0
        PerfLog.mark("iCloud scan start")
        for case let url as URL in walk {
            seen += 1; if seen % 1000 == 0 { PerfLog.mark("iCloud scan \(seen) items, \(waiting) waiting") }
            let name = url.lastPathComponent
            if let logical = ReaderFiles.logicalName(ofPlaceholder:name) {
                waiting += 1
                try? manager.startDownloadingUbiquitousItem(at:url.deletingLastPathComponent().appendingPathComponent(logical))
            } else if let status = try? url.resourceValues(forKeys:[.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus, status == .notDownloaded {
                waiting += 1
                try? manager.startDownloadingUbiquitousItem(at:url)
            }
        }
        return waiting
    }
}
