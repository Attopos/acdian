import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Color {
    // Reference screenshot accent converted from Display P3 to sRGB: #D93B86.
    static let acPink = Color(.sRGB,red:217.0/255,green:59.0/255,blue:134.0/255,opacity:1)
    // Each surface has a dark and a light value that follows the window's appearance.
    static func adaptive(dark: NSColor, light: NSColor) -> Color { Color(nsColor:NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .aqua ? light : dark }) }
    static let canvas = adaptive(dark:NSColor(red:0.065,green:0.065,blue:0.078,alpha:1),light:.white)
    static let rail = adaptive(dark:NSColor(red:0.088,green:0.088,blue:0.104,alpha:1),light:NSColor(red:0.965,green:0.961,blue:0.973,alpha:1))
    static let faint = adaptive(dark:NSColor.white.withAlphaComponent(0.07),light:NSColor.black.withAlphaComponent(0.08))
    static let ink = adaptive(dark:NSColor(red:0.96,green:0.95,blue:0.97,alpha:1),light:NSColor(red:0.09,green:0.086,blue:0.106,alpha:1))
    static let wash = adaptive(dark:NSColor.white.withAlphaComponent(0.045),light:NSColor.black.withAlphaComponent(0.04))
}
// The A and C strokes of the app icon (IconGenerator.swift), in its 1024 canvas
// whose 914-point tile starts at 55, scaled so the tile fills the given rect.
struct ACdianGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var strokes = Path()
        strokes.move(to:CGPoint(x:196,y:742)); strokes.addLine(to:CGPoint(x:328,y:318))
        strokes.addCurve(to:CGPoint(x:374,y:318),control1:CGPoint(x:340,y:278),control2:CGPoint(x:362,y:278))
        strokes.addLine(to:CGPoint(x:455,y:596))
        strokes.addCurve(to:CGPoint(x:672,y:790),control1:CGPoint(x:490,y:720),control2:CGPoint(x:570,y:790))
        strokes.addCurve(to:CGPoint(x:856,y:678),control1:CGPoint(x:762,y:790),control2:CGPoint(x:826,y:744))
        strokes.move(to:CGPoint(x:856,y:352))
        strokes.addCurve(to:CGPoint(x:672,y:246),control1:CGPoint(x:826,y:290),control2:CGPoint(x:762,y:246))
        strokes.addCurve(to:CGPoint(x:540,y:296),control1:CGPoint(x:618,y:246),control2:CGPoint(x:574,y:264))
        // translate(512 512) scale(.88) translate(-512 -512) translate(22 -4) skewX(-5), innermost first.
        let mark = CGAffineTransform(a:1,b:0,c:tan(-5 * .pi / 180),d:1,tx:0,ty:0)
            .concatenating(CGAffineTransform(translationX:22,y:-4))
            .concatenating(CGAffineTransform(translationX:-512,y:-512))
            .concatenating(CGAffineTransform(scaleX:0.88,y:0.88))
            .concatenating(CGAffineTransform(translationX:512,y:512))
        let scale = min(rect.width,rect.height) / 914
        let fit = CGAffineTransform(translationX:-55,y:-55).concatenating(CGAffineTransform(scaleX:scale,y:scale)).concatenating(CGAffineTransform(translationX:rect.minX,y:rect.minY))
        return strokes.strokedPath(StrokeStyle(lineWidth:112,lineCap:.round,lineJoin:.round)).applying(mark).applying(fit)
    }
}
extension AppIconStyle {
    static let ink = Color(.sRGB,red:0x14/255.0,green:0x12/255.0,blue:0x17/255.0,opacity:1)
    var tile: Color { self == .pink ? .acPink : Self.ink }
    var glyph: Color { self == .pink ? Self.ink : .acPink }
}
struct BrandMark: View {
    var size: CGFloat = 36
    var style: AppIconStyle = .pink
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let corner = size * 211 / 914
        ZStack {
            RoundedRectangle(cornerRadius:corner).fill(style.tile)
            ACdianGlyph().fill(style.glyph)
        }
        .overlay { if style == .black && colorScheme == .dark { RoundedRectangle(cornerRadius:corner).strokeBorder(Color.white.opacity(0.10),lineWidth:1) } }
        .frame(width:size,height:size)
    }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var outlineFloating = false
    var body: some View {
        HStack(spacing:0) {
            if model.showSidebar { SidebarView().frame(minWidth:220,idealWidth:256,maxWidth:300); Rectangle().fill(Color.faint).frame(width:1) }
            VStack(spacing:0) {
                // No top bar: open pages sit as tabs in a transparent strip that
                // keeps clear of the window controls and still drags the window.
                // A hidden sidebar comes back with Control-Command-S or View > Show or hide sidebar.
                TabStrip().frame(height:30)
                if model.showingTrash { TrashView(model:model) }
                else if model.selected != nil { documentBody }
                else { HomeArea() }
                Rectangle().fill(Color.faint).frame(height:1)
                statusBar
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .background(Color.canvas).tint(.acPink)
        .environment(\.locale,model.language.locale)
        .frame(minWidth:920,minHeight:620)
        .alert("ACdian",isPresented:Binding(get:{model.error != nil},set:{if !$0 { model.error = nil }})) { Button(model.localized("好"),role:.cancel) { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var pdfControls: some View {
        HStack(spacing:12) {
            Button { model.pdfPage = max(1,model.pdfPage-1) } label: { Image(systemName:"chevron.left") }.disabled(model.pdfPage <= 1).help(model.localized("上一页"))
            Text("\(model.language.number(model.pdfPage)) / \(model.language.number(model.pdfPageCount))").font(.system(size:12).monospacedDigit()).frame(minWidth:48)
            Button { model.pdfPage = min(model.pdfPageCount,model.pdfPage+1) } label: { Image(systemName:"chevron.right") }.disabled(model.pdfPage >= model.pdfPageCount).help(model.localized("下一页"))
            Divider().frame(height:16)
            Button { model.pdfZoomAction -= 1 } label:{ Image(systemName:"minus.magnifyingglass") }.help(model.localized("缩小"))
            Button { model.pdfZoomAction += 1 } label:{ Image(systemName:"plus.magnifyingglass") }.help(model.localized("放大"))
        }
    }
    @ViewBuilder private var documentBody: some View {
        if let file = model.selected {
            VStack(spacing:0) {
                if file.ext == "md" {
                    // The text column stays centred in the whole article area; the
                    // outline floats in the left margin when it fits there, and
                    // otherwise opens over the text from a » button.
                    GeometryReader { geometry in
                        let fits = geometry.size.width >= Self.outlineFitWidth
                        ZStack(alignment:.topLeading) {
                            VStack(spacing:0) {
                                if model.isDraft { DraftTitleView(model:model).id(model.editorDocumentID) }
                                LiveMarkdownEditor(model:model).frame(minWidth:360,maxWidth:.infinity,maxHeight:.infinity)
                            }
                            if model.showOutline && (fits || outlineFloating) {
                                outline(title:model.isDraft ? model.draftTitle : file.url.deletingPathExtension().lastPathComponent,floating:!fits)
                            } else {
                                Button { withAnimation(.easeInOut(duration:0.18)) { if fits { model.showOutline = true } else { model.showOutline = true; outlineFloating = true } } } label: { Image(systemName:"chevron.right.2").font(.system(size:11,weight:.medium)).frame(width:22,height:22).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("文章目录")).padding(.leading,20).padding(.top,39)
                            }
                        }
                    }
                } else if file.ext == "pdf" { PDFPane(url:file.url,model:model).id(file.id) }
                else if AppModel.images.contains(file.ext) { ImagePane(url:file.url).id(file.id) }
                else if AppModel.videos.contains(file.ext) { VideoPane(url:file.url).id(file.id) }
                else if !model.text.isEmpty { ScrollView { Text(model.text).font(.system(size:13,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(28) } }
                else { unsupported(file) }
            // Markdown pages share one editor, which swaps documents in place.
            }.id(file.ext == "md" ? "markdown" : file.id)
        }
    }
    // A Feishu-style outline in the page's left margin: the page title first,
    // then its headings, with no panel chrome of its own.
    // The editor column is at most 860 wide with 58 of empty padding inside each
    // edge; the outline (220) fits when the margin left of the text holds it plus a gap.
    static let outlineFitWidth: CGFloat = 860 + 2 * (220 + 12 - 58)
    private func outline(title: String, floating: Bool) -> some View {
        VStack(alignment:.leading,spacing:0) {
            Button { withAnimation(.easeInOut(duration:0.18)) { if floating { outlineFloating = false } else { model.showOutline = false } } } label: { Image(systemName:"chevron.left.2").font(.system(size:11,weight:.medium)) }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("文章目录")).padding(.bottom,16)
            ScrollView {
                VStack(alignment:.leading,spacing:4) {
                    Button { model.anchor = "#"; model.activeHeading = -1 } label: { Text(title.isEmpty ? "New Page" : title).font(.system(size:13,weight:.medium)).foregroundStyle(model.activeHeading < 0 ? Color.acPink : Color.primary.opacity(0.85)).lineLimit(2).multilineTextAlignment(.leading).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    ForEach(Array(model.headings.enumerated()),id:\.offset) { index,heading in
                        Button { model.anchor = heading.title; model.activeHeading = index } label: { Text(heading.title).font(.system(size:13)).foregroundStyle(index == model.activeHeading ? Color.acPink : heading.level <= 2 ? Color.primary.opacity(0.85) : Color.secondary).lineLimit(2).multilineTextAlignment(.leading).padding(.leading,CGFloat(max(0,heading.level-1))*12).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(.leading,24).padding(.trailing,8).padding(.top,43).padding(.bottom,floating ? 16 : 0).frame(width:220,alignment:.topLeading)
        .background { if floating { RoundedRectangle(cornerRadius:10).fill(Color.canvas).shadow(color:.black.opacity(0.25),radius:16,y:6).padding(.top,30).padding(.leading,10) } }
        .frame(maxHeight:.infinity,alignment:.top)
    }
    private func unsupported(_ file: VaultEntry) -> some View { VStack(spacing:18) { Image(systemName:"doc").font(.system(size:48,weight:.ultraLight)).foregroundStyle(Color.acPink); Text(file.name).font(.title2); Text(model.localized("此类文件可在系统默认应用中打开。")).foregroundStyle(.secondary); Button(model.localized("打开文件")) { NSWorkspace.shared.open(file.url) }.buttonStyle(.bordered) }.frame(maxWidth:.infinity,maxHeight:.infinity) }
    private var statusBar: some View {
        HStack(spacing:7) {
            if !model.showSidebar { LanguageMenu().padding(.trailing,5) }
            if model.loading { ProgressView().controlSize(.mini).scaleEffect(0.7) } else { Circle().fill(Color.acPink).frame(width:5,height:5) }
            Text(model.status).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.selected?.ext == "md" { Text(model.language.characterCount(model.wordCount)); Text("·").padding(.horizontal,3); Text("Markdown"); Text("UTF-8").padding(.leading,12) }
            else if model.selected?.ext == "pdf" { pdfControls.font(.system(size:11)).foregroundStyle(.secondary).buttonStyle(.borderless) }
            else if let file = model.selected, !model.showingTrash { Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName:"folder") }.buttonStyle(.borderless).help(model.localized("在 Finder 中显示")) }
        }.font(.system(size:10)).foregroundStyle(.tertiary).padding(.horizontal,20).frame(height:29)
    }
}

// Tabs share the strip's width evenly, like browser tabs, up to a comfortable maximum.
struct TabStrip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let leading: CGFloat = model.showSidebar ? 10 : 78
            let width = model.tabs.isEmpty ? 0 : min(200,max(36,(geometry.size.width - leading - 10) / CGFloat(model.tabs.count) - 2))
            HStack(spacing:2) {
                ForEach(model.tabs) { tab in TabButton(tab:tab,active:tab.id == model.activeTabID && model.selected != nil && !model.showingTrash).frame(width:width) }
            }.padding(.leading,leading).padding(.top,4).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
        }.contentShape(Rectangle()).clipped()
    }
}
struct TabButton: View {
    @EnvironmentObject var model: AppModel
    let tab: PageTab
    let active: Bool
    @State private var hovering = false
    var body: some View {
        HStack(spacing:2) {
            Text(model.tabTitle(tab)).font(.system(size:12)).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
            Button { model.closeTab(tab.id) } label: { Image(systemName:"xmark").font(.system(size:8,weight:.bold)).frame(width:16,height:16).contentShape(Rectangle()) }
                .buttonStyle(.plain).opacity(active || hovering ? 1 : 0).accessibilityLabel(model.localized("关闭标签页"))
        }
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.leading,10).padding(.trailing,4).frame(height:24)
        .background(active ? Color.wash : .clear,in:RoundedRectangle(cornerRadius:6))
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { hovering = $0 }
    }
}

struct SidebarToggle: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { withAnimation(.easeInOut(duration:0.18)) { model.showSidebar.toggle() } } label: { Image(systemName:"sidebar.left").font(.system(size:14)).frame(width:24,height:22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("显示或隐藏侧栏") + " ⌃⌘S")
    }
}
struct DraftTitleView: View {
    @ObservedObject var model: AppModel
    @FocusState private var titleFocused: Bool
    var body: some View {
        TextField("",text:$model.draftTitle,prompt:Text("New Page").foregroundColor(Color.primary.opacity(0.25)))
            .textFieldStyle(.plain)
            .font(.system(size:model.fontSize * 2.125,weight:.bold))
            .foregroundStyle(Color.ink)
            .focused($titleFocused)
            .accessibilityLabel("New Page")
            .accessibilityIdentifier("draftTitle")
            .onSubmit { titleFocused = false; model.editorFocus?() }
            .padding(.horizontal,58).padding(.top,43).padding(.bottom,8)
            .frame(maxWidth:860,alignment:.leading)
            .frame(maxWidth:.infinity)
            .onAppear { titleFocused = true }
    }
}


struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var rootDropTargeted = false
    @State private var editingModule: ModuleEditorTarget?
    var body: some View {
        // With no module open and no search, the sidebar lists the modules instead of folders.
        let home = model.activeModule == nil && model.query.isEmpty
        VStack(spacing:0) {
            HStack(spacing:10) { BrandMark(size:30,style:model.iconStyle); Text("ACdian").font(.system(size:21,weight:.semibold,design:.rounded)).tracking(-0.6); Spacer(); SidebarToggle() }.padding(.horizontal,20).frame(height:68)
            ModuleBar()
            HStack(spacing:8) { Image(systemName:"magnifyingglass").font(.system(size:12)); TextField(model.localized("搜索页面与内容"),text:$model.query).textFieldStyle(.plain).font(.system(size:12)).focused($searchFocused); if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).help(model.localized("清除搜索")) } else { Text("⌘F").font(.system(size:10)).foregroundStyle(.tertiary) } }.foregroundStyle(.secondary).padding(10).background(Color.wash,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.faint)).padding(.horizontal,14).padding(.bottom,20)
            if home {
                HStack { Text(model.localized("模块")).font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(Color.secondary.opacity(0.6)); Spacer(); Button { model.refresh() } label: { Image(systemName:"arrow.clockwise") }.help(model.localized("刷新页面")); Button { editingModule = .new } label: { Image(systemName:"plus") }.help(model.localized("新建模块")) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,10)
            } else {
            HStack { Text(model.query.isEmpty ? model.localized("页面") : model.localized("搜索结果 · %@",model.language.number(model.matches.count))).font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(rootDropTargeted ? Color.acPink : Color.secondary.opacity(0.6)).onDrop(of:[.text],isTargeted:$rootDropTargeted) { providers in
                // Dropping on the Pages header moves an item to the top level.
                let folder = model.activeModule?.folder ?? ""
                if let path = model.draggingPath { model.movePage(path,to:PageDropTarget(folder:folder)); return true }
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass:NSString.self) { object,_ in if let path = object as? String { DispatchQueue.main.async { model.movePage(path,to:PageDropTarget(folder:folder)) } } }
                return true
            }; Spacer(); Button { model.refresh() } label: { Image(systemName:"arrow.clockwise") }.help(model.localized("刷新页面")); Button { model.newFolder(in:model.activeModule?.folder ?? "") } label: { Image(systemName:"folder.badge.plus") }.help(model.localized("新建文件夹")); Button { model.newPageFromEditor() } label: { Image(systemName:"square.and.pencil") }.help(model.localized("新建页面 ⌘N")) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,10)
            }
            ScrollView {
                if home { SidebarModuleList { editingModule = $0 }.padding(.horizontal,10).padding(.bottom,20) }
                else if model.query.isEmpty { SidebarTree(entries:model.sidebarEntries).padding(.horizontal,10).padding(.bottom,20) }
                else {
                    let matches = model.matches
                    LazyVStack(spacing:2) { ForEach(matches.prefix(500)) { entry in FileRow(entry:entry,indent:0,showPath:true) }; if matches.isEmpty { Text(model.localized("没有找到匹配的文件")).font(.caption).foregroundStyle(.tertiary).padding(.top,25) } }
                        .padding(.horizontal,10).padding(.bottom,20)
                }
            }
            Spacer(minLength:0)
            Button { model.showTrash() } label: {
                HStack(spacing:10) { Image(systemName:"trash").frame(width:16); Text(model.localized("垃圾桶")); Spacer() }
                    .font(.system(size:12,weight:.medium)).foregroundStyle(model.showingTrash ? Color.acPink : Color.secondary)
                    .padding(.horizontal,12).padding(.vertical,9)
                    .background(model.showingTrash ? Color.acPink.opacity(0.09) : .clear,in:RoundedRectangle(cornerRadius:7))
            }.buttonStyle(.plain).padding(.horizontal,10).padding(.bottom,12)
                .accessibilityIdentifier("trashButton")
            Rectangle().fill(Color.faint).frame(height:1).padding(.horizontal,16)
            HStack(spacing:14) { SettingsButton(); Spacer() }.padding(.horizontal,20).padding(.vertical,14)
        }.background(Color.rail)
        .sheet(item:$editingModule) { target in ModuleEditor(target:target).environmentObject(model) }
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("acdianSearch"))) { _ in searchFocused = true; model.showSidebar = true }
    }
}
/// The folder tree as one flat, lazily drawn list, so folders with thousands
/// of pages open without drawing every row.
struct SidebarTree: View {
    @EnvironmentObject var model: AppModel
    let entries: [VaultEntry]
    private struct Row: Identifiable { let entry: VaultEntry; let depth: Int; var id: String { entry.relativePath } }
    private func rows() -> [Row] {
        var list: [Row] = []
        func add(_ entries: [VaultEntry], _ depth: Int) {
            for entry in entries {
                list.append(Row(entry:entry,depth:depth))
                if entry.isDirectory, model.isExpanded(entry,depth:depth) { add(entry.children ?? [],depth + 1) }
            }
        }
        add(entries,0)
        return list
    }
    var body: some View {
        let _ = model.folderStateRevision
        LazyVStack(spacing:2) { ForEach(rows()) { row in TreeRow(entry:row.entry,depth:row.depth) } }
    }
}
struct TreeRow: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    let depth: Int
    var body: some View {
        let expanded = entry.isDirectory && model.isExpanded(entry,depth:depth)
        if entry.isDirectory, model.renamingPath == entry.relativePath {
            RenameRow(entry:entry,leading:CGFloat(depth)*13+8,folder:true,symbol:expanded ? "folder.fill" : "folder",tint:Color.acPink.opacity(0.72)).id(model.renamingSession)
        } else if entry.isDirectory {
            Button { model.setFolderExpanded(entry.relativePath,!expanded) } label: {
                HStack(spacing:6) { Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.system(size:8,weight:.semibold)).frame(width:8); Image(systemName:expanded ? "folder.fill" : "folder").font(.system(size:12)).foregroundStyle(Color.acPink.opacity(0.72)); Text(entry.name).font(.system(size:12)).lineLimit(1); Spacer() }.foregroundStyle(.secondary).padding(.leading,CGFloat(depth)*13+8).padding(.trailing,8).frame(height:29).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count:2).onEnded { model.startRenaming(entry) })
            .contextMenu {
                Button { if model.newFolder(near:entry) != nil { model.setFolderExpanded(entry.relativePath,true) } } label: { Label(model.localized("新建文件夹"),systemImage:"folder.badge.plus") }
                Button { model.startRenaming(entry) } label: { Label(model.localized("重命名"),systemImage:"pencil") }
                MoveToMenu(entry:entry)
                Divider()
                Button(role:.destructive) { model.delete(entry) } label: { Label(model.localized("删除"),systemImage:"trash") }
            }
            .sidebarDropIndicator(model.sidebarDrop?.path == entry.relativePath ? model.sidebarDrop?.place : nil)
            .onDrag { model.draggingPath = entry.relativePath; return NSItemProvider(object:entry.relativePath as NSString) }
            .onDrop(of:[.text],delegate:SidebarDropDelegate(model:model,entry:entry,height:29) { model.setFolderExpanded(entry.relativePath,true) })
        } else { FileRow(entry:entry,indent:depth) }
    }
}
/// The main area with no page open: the module launcher, or the open module's home.
struct HomeArea: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let module = model.activeModule {
            if module.kind == .attachments { AttachmentsView(module:module) } else { ModuleHomeView(module:module) }
        } else { LauncherView() }
    }
}
/// A sidebar row whose name is being edited in place. Return or clicking
/// anywhere else keeps the typed name; Escape keeps the old one.
struct RenameRow: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    let leading: CGFloat
    var folder = false
    let symbol: String
    let tint: Color
    var body: some View {
        let name = AppModel.editableName(entry)
        // Like Finder, a file's extension starts unselected.
        let stem = folder || name != entry.name ? name : (name as NSString).deletingPathExtension
        HStack(spacing:folder ? 6 : 8) {
            if folder { Image(systemName:"chevron.right").font(.system(size:8,weight:.semibold)).frame(width:8).foregroundStyle(.secondary) }
            Image(systemName:symbol).font(.system(size:12)).frame(width:folder ? nil : 14).foregroundStyle(tint)
            NameEditor(initial:name,selected:(stem as NSString).length) { typed in model.finishRenaming(entry.relativePath,to:typed) }
                .frame(maxWidth:.infinity).padding(.horizontal,4).padding(.vertical,2)
                .background(Color.wash,in:RoundedRectangle(cornerRadius:4))
                .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(Color.acPink.opacity(0.6)))
        }.padding(.leading,leading).padding(.trailing,8).frame(height:29)
    }
}
private struct NameEditor: NSViewRepresentable {
    let initial: String
    let selected: Int
    let finish: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finish) }
    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingField(string:initial)
        field.selected = NSRange(location:0,length:selected)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize:12); field.lineBreakMode = .byClipping; field.cell?.isScrollable = true
        field.setAccessibilityIdentifier("sidebarNameField")
        field.delegate = context.coordinator
        context.coordinator.watch(field)
        return field
    }
    /// Takes the keyboard, with its name selected, once it is on screen.
    final class FocusingField: NSTextField {
        var selected = NSRange(location:0,length:0)
        private var focused = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !focused, window != nil else { return }
            focused = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self); self.currentEditor()?.selectedRange = self.selected
            }
        }
    }
    func updateNSView(_ field: NSTextField, context: Context) {}
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { coordinator.stopWatching() }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let finish: (String?) -> Void
        private weak var field: NSTextField?
        private var monitor: Any?
        private var cancelled = false, done = false
        init(_ finish: @escaping (String?) -> Void) { self.finish = finish }
        /// Like Finder, a click anywhere else in the window ends editing.
        func watch(_ field: NSTextField) {
            self.field = field
            monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] event in
                if let field = self?.field, event.window === field.window,
                   !field.bounds.contains(field.convert(event.locationInWindow,from:nil)) { field.window?.makeFirstResponder(nil) }
                return event
            }
        }
        func stopWatching() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            cancelled = selector == #selector(NSResponder.cancelOperation(_:))
            control.window?.makeFirstResponder(nil)
            return true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !done, let field else { return }
            done = true; stopWatching()
            finish(cancelled ? nil : field.stringValue)
        }
    }
}
struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    var indent: Int
    var showPath = false
    var symbol: String { if entry.ext == "md" { return "doc.text" }; if entry.ext == "pdf" { return "doc.richtext" }; if AppModel.images.contains(entry.ext) { return "photo" }; if AppModel.videos.contains(entry.ext) { return "film" }; return "doc" }
    private var isCurrentPage: Bool { model.currentPagePath == entry.relativePath }
    var body: some View {
        if model.renamingPath == entry.relativePath {
            RenameRow(entry:entry,leading:CGFloat(indent)*13+23,symbol:symbol,tint:Color.acPink).id(model.renamingSession)
        } else { row }
    }
    private var row: some View {
        Button { model.open(entry) } label: {
            HStack(spacing:8) { Image(systemName:symbol).font(.system(size:12)).frame(width:14).foregroundStyle(isCurrentPage ? Color.acPink : Color.secondary.opacity(0.65)); VStack(alignment:.leading,spacing:3) { Text(entry.ext == "md" ? String(entry.name.dropLast(3)) : entry.name).font(.system(size:12)).lineLimit(1); if showPath { Text(entry.relativePath).font(.system(size:9)).foregroundStyle(.tertiary).lineLimit(1) } }; Spacer(minLength:0) }.foregroundStyle(isCurrentPage ? Color.primary : Color.secondary).padding(.leading,CGFloat(indent)*13+23).padding(.trailing,10).padding(.vertical,7).contentShape(Rectangle()).background(isCurrentPage ? Color.acPink.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).help(entry.relativePath)
        .simultaneousGesture(TapGesture(count:2).onEnded { model.startRenaming(entry) })
        .contextMenu {
            Button { model.newFolder(near:entry) } label: { Label(model.localized("新建文件夹"),systemImage:"folder.badge.plus") }
            Button { model.startRenaming(entry) } label: { Label(model.localized("重命名"),systemImage:"pencil") }
            MoveToMenu(entry:entry)
            Divider()
            Button(role:.destructive) { model.delete(entry) } label: { Label(model.localized("删除"),systemImage:"trash") }
        }
        .sidebarDropIndicator(model.sidebarDrop?.path == entry.relativePath ? model.sidebarDrop?.place : nil)
        .onDrag { model.draggingPath = entry.relativePath; return NSItemProvider(object:entry.relativePath as NSString) }
        .onDrop(of:[.text],delegate:SidebarDropDelegate(model:model,entry:entry,height:nil))
    }
}
/// "Move to" in a sidebar row's menu: every module and the folders inside it,
/// plus the top level. A folder with subfolders opens a submenu that starts
/// with "Move here".
struct MoveToMenu: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    var body: some View {
        let parent = (entry.relativePath as NSString).deletingLastPathComponent
        Menu {
            ForEach(model.presentModules) { module in
                if let folder = model.index.flatMap({ AppModel.entry(module.folder,in:$0.entries) }) {
                    MoveFolderMenu(folder:folder,title:module.name,moving:entry)
                }
            }
            Divider()
            Button(model.localized("顶层")) { model.movePage(entry.relativePath,to:PageDropTarget(folder:"")) }.disabled(parent.isEmpty)
        } label: { Label(model.localized("移动到"),systemImage:"folder") }
    }
}
struct MoveFolderMenu: View {
    @EnvironmentObject var model: AppModel
    let folder: VaultEntry
    let title: String
    let moving: VaultEntry
    var body: some View {
        let path = folder.relativePath
        let blocked = path == moving.relativePath || path.hasPrefix(moving.relativePath + "/")
        let here = path == (moving.relativePath as NSString).deletingLastPathComponent
        let subfolders = (folder.children ?? []).filter { $0.isDirectory && $0.relativePath != moving.relativePath }
        if blocked { EmptyView() }
        else if subfolders.isEmpty {
            Button(title) { model.movePage(moving.relativePath,to:PageDropTarget(folder:path)) }.disabled(here)
        } else {
            Menu(title) {
                Button(model.localized("移到这里")) { model.movePage(moving.relativePath,to:PageDropTarget(folder:path)) }.disabled(here)
                Divider()
                ForEach(subfolders) { child in AnyView(MoveFolderMenu(folder:child,title:child.name,moving:moving)) }
            }
        }
    }
}
// Dragging a sidebar row: the top or bottom edge of a row places the item
// before or after it, and the middle of a folder row moves the item inside.
struct SidebarDropDelegate: DropDelegate {
    let model: AppModel
    let entry: VaultEntry
    let height: CGFloat?
    var onInto: () -> Void = {}
    private func placement(_ info: DropInfo) -> SidebarDrop {
        let y = info.location.y, rowHeight = height ?? 34
        if entry.isDirectory { return y < rowHeight * 0.25 ? .before : y > rowHeight * 0.75 ? .after : .into }
        return y < rowHeight / 2 ? .before : .after
    }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to:[.text]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { model.setSidebarDrop(SidebarDropHighlight(path:entry.relativePath,place:placement(info))); return DropProposal(operation:.move) }
    func dropExited(info: DropInfo) { if model.sidebarDrop?.path == entry.relativePath { model.setSidebarDrop(nil) } }
    func performDrop(info: DropInfo) -> Bool {
        let place = placement(info); model.setSidebarDrop(nil)
        let parent = entry.relativePath.split(separator:"/").dropLast().joined(separator:"/")
        let target = place == .into ? PageDropTarget(folder:entry.relativePath) : PageDropTarget(folder:parent,anchor:entry.name,after:place == .after)
        let finish = { (path: String) in
            guard path != entry.relativePath else { return }
            model.movePage(path,to:target); if place == .into { onInto() }
        }
        // A drag that started in this sidebar is moved at once; the item
        // provider is only read for drags that arrive from elsewhere.
        if let path = model.draggingPath { finish(path); return true }
        guard let provider = info.itemProviders(for:[.text]).first else { return false }
        _ = provider.loadObject(ofClass:NSString.self) { object,_ in
            if let path = object as? String { DispatchQueue.main.async { finish(path) } }
        }
        return true
    }
}
extension View {
    func sidebarDropIndicator(_ drop: SidebarDrop?) -> some View {
        overlay(alignment:drop == .after ? .bottom : .top) {
            if drop == .before || drop == .after { Rectangle().fill(Color.acPink).frame(height:2).padding(.horizontal,8) }
        }
        .background(drop == .into ? Color.acPink.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:6))
    }
}
struct TrashView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(model.localized("垃圾桶")).font(.system(size:28,weight:.bold))
            Text(model.localized("删除的文件会保留 15 天，之后自动彻底删除。"))
                .font(.system(size:12)).foregroundStyle(.secondary)
            if model.trashEntries.isEmpty {
                VStack(spacing:14) {
                    Image(systemName:"trash").font(.system(size:38,weight:.ultraLight)).foregroundStyle(.tertiary)
                    Text(model.localized("垃圾桶是空的")).font(.system(size:13)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing:8) {
                        ForEach(model.trashEntries) { entry in
                            HStack(spacing:13) {
                                Image(systemName:entry.isDirectory ? "folder" : "doc.text").font(.system(size:21)).foregroundStyle(Color.acPink).frame(width:28)
                                VStack(alignment:.leading,spacing:5) {
                                    Text(entry.name).font(.system(size:13,weight:.medium)).lineLimit(1)
                                    Text(entry.originalRelativePath).font(.system(size:10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                    HStack(spacing:12) {
                                        Text(model.localized("删除于 %@",model.language.modifiedDate(entry.deletedAt)))
                                        Text(model.language.remainingTrashDays(model.trashDaysRemaining(entry)))
                                    }.font(.system(size:10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength:12)
                                Button(model.localized("恢复")) { model.restoreFromTrash(entry) }.buttonStyle(.bordered)
                                    .accessibilityIdentifier("restore-\(entry.id.uuidString)")
                            }.padding(15).background(Color.wash,in:RoundedRectangle(cornerRadius:9))
                        }
                    }.padding(.top,7)
                }
            }
        }.padding(32).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(Color.canvas)
    }
}

/// Kept outside the document identity so a language change never reloads edits.
// The gear at the foot of the sidebar opens icon, language and appearance settings.
struct SettingsButton: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Image(systemName:"gearshape").font(.system(size:15,weight:.medium)).frame(width:22,height:20).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(open ? Color.acPink : Color.secondary)
            .help(model.localized("设置")).accessibilityLabel(model.localized("设置")).accessibilityIdentifier("settingsButton")
            .popover(isPresented:$open,arrowEdge:.top) { SettingsPanel().environmentObject(model) }
    }
}
struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            section("图标") {
                HStack(spacing:14) {
                    ForEach(AppIconStyle.allCases) { style in
                        let selected = model.iconStyle == style
                        Button { model.iconStyle = style } label: {
                            BrandMark(size:44,style:style).padding(4)
                                .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(selected ? Color.acPink : Color.faint,lineWidth:selected ? 2 : 1))
                        }.buttonStyle(.plain).help(model.localized(style.title))
                        .accessibilityLabel(model.localized(style.title)).accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            section("语言") {
                SettingsSegments(options:AppLanguage.allCases,selection:model.language,title:\.name) { AppDelegate.switchLanguage(to:$0,model:model) }
            }
            section("外观") {
                SettingsSegments(options:AppAppearance.allCases,selection:model.appearance,title:{ model.localized($0.title) }) { model.appearance = $0 }
            }
        }.padding(18).frame(width:330,alignment:.leading).tint(.acPink)
    }
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(model.localized(title)).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
// A compact segmented row whose selected segment takes the theme pink.
struct SettingsSegments<Option: Identifiable & Equatable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let choose: (Option) -> Void
    var body: some View {
        HStack(spacing:2) {
            ForEach(options) { option in
                let selected = option == selection
                Button { if !selected { choose(option) } } label: {
                    Text(title(option)).font(.system(size:11,weight:selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal,3)
                        .frame(maxWidth:.infinity).padding(.vertical,5)
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .background(selected ? Color.acPink : .clear,in:RoundedRectangle(cornerRadius:6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(2).background(Color.wash,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.faint))
    }
}
struct LanguageMenu: View {
    @EnvironmentObject var model: AppModel
    private var languageSymbol: String {
        ["translate","character.bubble","globe"].first {
            NSImage(systemSymbolName:$0,accessibilityDescription:nil) != nil
        } ?? "globe"
    }
    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button { AppDelegate.switchLanguage(to:language,model:model) } label: {
                    if model.language == language { Label(language.name,systemImage:"checkmark") }
                    else { Text(language.name) }
                }
            }
        } label: { Image(systemName:languageSymbol).font(.system(size:15,weight:.medium)).frame(width:22,height:20) }
        .menuStyle(.borderlessButton).fixedSize()
        .help(model.localized("语言：%@",model.language.name))
        .accessibilityLabel(model.localized("语言"))
        .accessibilityValue(model.language.name)
        .accessibilityIdentifier("languageMenu")
    }
}
