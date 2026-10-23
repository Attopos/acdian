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
struct BrandMark: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:size*0.29).fill(Color.acPink.opacity(0.13))
            Text("a").font(.system(size:size*0.87,weight:.semibold,design:.rounded)).italic().foregroundStyle(Color.acPink).offset(x:-size*0.025,y:-size*0.09)
        }.frame(width:size,height:size)
    }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing:0) {
            if model.showSidebar { SidebarView().frame(minWidth:220,idealWidth:256,maxWidth:300); Rectangle().fill(Color.faint).frame(width:1) }
            VStack(spacing:0) {
                topBar
                Rectangle().fill(Color.faint).frame(height:1)
                if model.showingTrash { TrashView(model:model) }
                else if model.selected != nil { documentBody }
                else { Color.canvas.frame(maxWidth:.infinity,maxHeight:.infinity) }
                Rectangle().fill(Color.faint).frame(height:1)
                statusBar
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .background(Color.canvas).tint(.acPink)
        .environment(\.locale,model.language.locale)
        .frame(minWidth:920,minHeight:620)
        .alert("acdian",isPresented:Binding(get:{model.error != nil},set:{if !$0 { model.error = nil }})) { Button(model.localized("好"),role:.cancel) { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var topBar: some View {
        HStack(spacing:12) {
            Button { withAnimation(.easeInOut(duration:0.18)) { model.showSidebar.toggle() } } label: { Image(systemName:"sidebar.left") }.help(model.localized("显示或隐藏侧栏"))
            if model.showingTrash {
                Label(model.localized("垃圾桶"),systemImage:"trash").font(.system(size:13,weight:.medium))
            } else if let file = model.selected {
                HStack(spacing:7) {
                    Image(systemName:file.ext == "md" ? "doc.text" : file.ext == "pdf" ? "doc.richtext" : "doc").foregroundStyle(Color.acPink)
                    Text(model.isDraft ? (model.draftTitle.isEmpty ? "New Page" : model.draftTitle) : file.name).font(.system(size:13,weight:.medium)).lineLimit(1)
                }
            } else { Text("").font(.system(size:13)).foregroundStyle(.secondary) }
            Spacer(minLength:10)
            if model.selected?.ext == "md" {
            } else if model.selected?.ext == "pdf" { pdfControls }
            else if let file = model.selected {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName:"folder") }.help(model.localized("在 Finder 中显示"))
            }
        }.buttonStyle(.borderless).padding(.horizontal,20).frame(height:58)
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
                    HStack(alignment:.top,spacing:0) {
                        if model.showOutline { outline(title:model.isDraft ? model.draftTitle : file.url.deletingPathExtension().lastPathComponent) }
                        else { Button { withAnimation(.easeInOut(duration:0.18)) { model.showOutline = true } } label: { Image(systemName:"chevron.right.2").font(.system(size:11,weight:.medium)) }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("文章目录")).padding(.leading,24).padding(.top,43) }
                        VStack(spacing:0) {
                            if model.isDraft { DraftTitleView(model:model) } else { PageTitleView(title:file.url.deletingPathExtension().lastPathComponent,fontSize:model.fontSize) }
                            LiveMarkdownEditor(model:model).id(model.editorDocumentID).frame(minWidth:360,maxWidth:.infinity,maxHeight:.infinity)
                        }
                    }
                } else if file.ext == "pdf" { PDFPane(url:file.url,model:model).id(file.id) }
                else if AppModel.images.contains(file.ext) { ImagePane(url:file.url).id(file.id) }
                else if !model.text.isEmpty { ScrollView { Text(model.text).font(.system(size:13,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(28) } }
                else { unsupported(file) }
            }.id(file.id)
        }
    }
    // A Feishu-style outline in the page's left margin: the page title first,
    // then its headings, with no panel chrome of its own.
    private func outline(title: String) -> some View {
        VStack(alignment:.leading,spacing:0) {
            Button { withAnimation(.easeInOut(duration:0.18)) { model.showOutline = false } } label: { Image(systemName:"chevron.left.2").font(.system(size:11,weight:.medium)) }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("文章目录")).padding(.bottom,16)
            ScrollView {
                VStack(alignment:.leading,spacing:4) {
                    Button { model.anchor = "#" } label: { Text(title.isEmpty ? "New Page" : title).font(.system(size:13,weight:.medium)).foregroundStyle(Color.acPink).lineLimit(2).multilineTextAlignment(.leading).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    ForEach(Array(model.headings.enumerated()),id:\.offset) { _,heading in
                        Button { model.anchor = heading.title } label: { Text(heading.title).font(.system(size:13)).foregroundStyle(heading.level <= 2 ? Color.primary.opacity(0.85) : Color.secondary).lineLimit(2).multilineTextAlignment(.leading).padding(.leading,CGFloat(max(0,heading.level-1))*12).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(.leading,24).padding(.trailing,8).padding(.top,43).frame(width:220,alignment:.topLeading).frame(maxHeight:.infinity,alignment:.top)
    }
    private func unsupported(_ file: VaultEntry) -> some View { VStack(spacing:18) { Image(systemName:"doc").font(.system(size:48,weight:.ultraLight)).foregroundStyle(Color.acPink); Text(file.name).font(.title2); Text(model.localized("此类文件可在系统默认应用中打开。")).foregroundStyle(.secondary); Button(model.localized("打开文件")) { NSWorkspace.shared.open(file.url) }.buttonStyle(.bordered) }.frame(maxWidth:.infinity,maxHeight:.infinity) }
    private var statusBar: some View {
        HStack(spacing:7) {
            if !model.showSidebar { LanguageMenu().padding(.trailing,5) }
            if model.loading { ProgressView().controlSize(.mini).scaleEffect(0.7) } else { Circle().fill(Color.acPink).frame(width:5,height:5) }
            Text(model.status).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.selected?.ext == "md" { Text(model.language.characterCount(model.wordCount)); Text("·").padding(.horizontal,3); Text("Markdown"); Text("UTF-8").padding(.leading,12) }
        }.font(.system(size:10)).foregroundStyle(.tertiary).padding(.horizontal,20).frame(height:29)
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

struct PageTitleView: View {
    let title: String
    let fontSize: Double
    var body: some View {
        Text(title)
            .font(.system(size:fontSize * 2.125,weight:.bold))
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal,58).padding(.top,43).padding(.bottom,8)
            .frame(maxWidth:860,alignment:.leading)
            .frame(maxWidth:.infinity)
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var rootDropTargeted = false
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:10) { BrandMark(size:30); Text("acdian").font(.system(size:21,weight:.semibold,design:.rounded)).tracking(-0.6); Spacer() }.padding(.horizontal,20).frame(height:68)
            HStack(spacing:8) { Image(systemName:"magnifyingglass").font(.system(size:12)); TextField(model.localized("搜索页面与内容"),text:$model.query).textFieldStyle(.plain).font(.system(size:12)).focused($searchFocused); if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).help(model.localized("清除搜索")) } else { Text("⌘F").font(.system(size:10)).foregroundStyle(.tertiary) } }.foregroundStyle(.secondary).padding(10).background(Color.wash,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.faint)).padding(.horizontal,14).padding(.bottom,20)
            HStack { Text(model.query.isEmpty ? model.localized("页面") : model.localized("搜索结果 · %@",model.language.number(model.matches.count))).font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(rootDropTargeted ? Color.acPink : Color.secondary.opacity(0.6)).onDrop(of:[.text],isTargeted:$rootDropTargeted) { providers in
                // Dropping on the Pages header moves an item to the top level.
                if let path = model.draggingPath { model.movePage(path,to:PageDropTarget(folder:"")); return true }
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass:NSString.self) { object,_ in if let path = object as? String { DispatchQueue.main.async { model.movePage(path,to:PageDropTarget(folder:"")) } } }
                return true
            }; Spacer(); Button { model.refresh() } label: { Image(systemName:"arrow.clockwise") }.help(model.localized("刷新页面")); Button { model.newPageFromEditor() } label: { Image(systemName:"square.and.pencil") }.help(model.localized("新建页面 ⌘N")) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,10)
            ScrollView {
                VStack(spacing:2) {
                    if model.query.isEmpty { ForEach(model.index?.entries ?? []) { entry in TreeRow(entry:entry,depth:0) } }
                    else { ForEach(model.matches) { entry in FileRow(entry:entry,indent:0,showPath:true) }; if model.matches.isEmpty { Text(model.localized("没有找到匹配的文件")).font(.caption).foregroundStyle(.tertiary).padding(.top,25) } }
                }.padding(.horizontal,10).padding(.bottom,20)
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
            HStack { LanguageMenu(); Spacer() }.padding(.horizontal,20).padding(.vertical,14)
        }.background(Color.rail)
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("acdianSearch"))) { _ in searchFocused = true; model.showSidebar = true }
    }
}
struct TreeRow: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    let depth: Int
    @State private var expanded = false
    var body: some View {
        VStack(spacing:2) {
            if entry.isDirectory {
                Button { withAnimation(.easeInOut(duration:0.12)) { expanded.toggle() } } label: {
                    HStack(spacing:6) { Image(systemName:expanded ? "chevron.down" : "chevron.right").font(.system(size:8,weight:.semibold)).frame(width:8); Image(systemName:expanded ? "folder.fill" : "folder").font(.system(size:12)).foregroundStyle(Color.acPink.opacity(0.72)); Text(entry.name).font(.system(size:12)).lineLimit(1); Spacer() }.foregroundStyle(.secondary).padding(.leading,CGFloat(depth)*13+8).padding(.trailing,8).frame(height:29).contentShape(Rectangle())
                }.buttonStyle(.plain).contextMenu {
                    Button(role:.destructive) { model.delete(entry) } label: { Label(model.localized("删除"),systemImage:"trash") }
                }
                .sidebarDropIndicator(model.sidebarDrop?.path == entry.relativePath ? model.sidebarDrop?.place : nil)
                .onDrag { model.draggingPath = entry.relativePath; return NSItemProvider(object:entry.relativePath as NSString) }
                .onDrop(of:[.text],delegate:SidebarDropDelegate(model:model,entry:entry,height:29) { expanded = true })
                if expanded { ForEach(entry.children ?? []) { child in TreeRow(entry:child,depth:depth+1) } }
            } else { FileRow(entry:entry,indent:depth) }
        }.onAppear { if depth == 0 && !["attachment","attachments","assets"].contains(entry.name.lowercased()) { expanded = true } }
    }
}
struct FileRow: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    var indent: Int
    var showPath = false
    var symbol: String { if entry.ext == "md" { return "doc.text" }; if entry.ext == "pdf" { return "doc.richtext" }; if AppModel.images.contains(entry.ext) { return "photo" }; return "doc" }
    private var isCurrentPage: Bool { model.currentPagePath == entry.relativePath }
    var body: some View {
        Button { model.open(entry) } label: {
            HStack(spacing:8) { Image(systemName:symbol).font(.system(size:12)).frame(width:14).foregroundStyle(isCurrentPage ? Color.acPink : Color.secondary.opacity(0.65)); VStack(alignment:.leading,spacing:3) { Text(entry.ext == "md" ? String(entry.name.dropLast(3)) : entry.name).font(.system(size:12)).lineLimit(1); if showPath { Text(entry.relativePath).font(.system(size:9)).foregroundStyle(.tertiary).lineLimit(1) } }; Spacer(minLength:0) }.foregroundStyle(isCurrentPage ? Color.primary : Color.secondary).padding(.leading,CGFloat(indent)*13+23).padding(.trailing,10).padding(.vertical,7).contentShape(Rectangle()).background(isCurrentPage ? Color.acPink.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).help(entry.relativePath).contextMenu {
            Button(role:.destructive) { model.delete(entry) } label: { Label(model.localized("删除"),systemImage:"trash") }
        }
        .sidebarDropIndicator(model.sidebarDrop?.path == entry.relativePath ? model.sidebarDrop?.place : nil)
        .onDrag { model.draggingPath = entry.relativePath; return NSItemProvider(object:entry.relativePath as NSString) }
        .onDrop(of:[.text],delegate:SidebarDropDelegate(model:model,entry:entry,height:nil))
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
