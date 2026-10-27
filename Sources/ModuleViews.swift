import SwiftUI
import AppKit
import AVKit
import QuickLookThumbnailing

/// Module colours: the app's pink and black first, then a few extras. The
/// colour tints the icon on a soft frosted tile; an open module's tile turns dark.
enum ModuleStyle {
    static func tile(_ name: String) -> Color {
        switch name {
        case "black": return Color.ink
        case "rose": return Color(.sRGB,red:0.88,green:0.42,blue:0.62,opacity:1)
        case "plum": return Color(.sRGB,red:0.52,green:0.30,blue:0.70,opacity:1)
        case "amber": return Color(.sRGB,red:0.93,green:0.62,blue:0.16,opacity:1)
        case "teal": return Color(.sRGB,red:0.12,green:0.62,blue:0.56,opacity:1)
        case "sky": return Color(.sRGB,red:0.22,green:0.50,blue:0.92,opacity:1)
        case "graphite": return Color(.sRGB,red:0.45,green:0.45,blue:0.50,opacity:1)
        default: return .acPink
        }
    }
    /// A two-tone fill for the icon, like a colourful app logo.
    static func glyph(_ name: String, active: Bool) -> LinearGradient {
        let base: Color = active && name == "black" ? .acPink : active && name == "graphite" ? .white : tile(name)
        let second: Color = name == "black" ? (active ? Color(.sRGB,red:0.97,green:0.55,blue:0.75,opacity:1) : .acPink) : base.opacity(0.62)
        return LinearGradient(colors:[base,second],startPoint:.topLeading,endPoint:.bottomTrailing)
    }
    static let frost = Color.adaptive(dark:NSColor.white.withAlphaComponent(0.07),light:NSColor(red:0.93,green:0.92,blue:0.95,alpha:1))
    static let frostEdge = Color.adaptive(dark:NSColor.white.withAlphaComponent(0.10),light:NSColor.black.withAlphaComponent(0.07))
    static let dark = Color.adaptive(dark:NSColor(red:0.20,green:0.20,blue:0.23,alpha:1),light:NSColor(red:0.16,green:0.16,blue:0.19,alpha:1))
    /// An SF Symbol that exists on this Mac, or a plain folder.
    static func symbol(_ name: String) -> String { NSImage(systemSymbolName:name,accessibilityDescription:nil) != nil ? name : "folder" }
}

/// A module's tile: a rounded, slightly wide frosted card with its icon in the
/// middle. `size` is the height; an active tile is dark, like a pressed key.
struct ModuleTileIcon: View {
    let icon: String
    let color: String
    var size: CGFloat = 76
    var active = false
    var hovering = false
    var body: some View {
        let corner = size * 0.24, width = (size * 1.3).rounded()
        ZStack {
            RoundedRectangle(cornerRadius:corner,style:.continuous).fill(active ? ModuleStyle.dark : ModuleStyle.frost)
            RoundedRectangle(cornerRadius:corner,style:.continuous).strokeBorder(active ? Color.white.opacity(0.12) : hovering ? Color.acPink.opacity(0.45) : ModuleStyle.frostEdge,lineWidth:size > 40 ? 1.5 : 1)
            Image(systemName:ModuleStyle.symbol(icon)).font(.system(size:size * 0.38,weight:.medium)).foregroundStyle(ModuleStyle.glyph(color,active:active))
        }
        .shadow(color:.black.opacity(active ? 0.28 : hovering ? 0.12 : 0),radius:size > 40 ? 10 : 3,y:size > 40 ? 4 : 1)
        .frame(width:width,height:size)
    }
}

/// The home screen: every module as a tile, like apps on a launcher.
struct LauncherView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: ModuleEditorTarget?
    @State private var showHidden = false
    @State private var dragging: String?
    private let columns = [GridItem(.adaptive(minimum:118,maximum:140),spacing:18,alignment:.top)]
    var body: some View {
        let present = model.presentModules
        let hidden = present.filter(\.hidden)
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                VStack(alignment:.leading,spacing:6) {
                    Text(model.localized("模块")).font(.system(size:28,weight:.bold))
                    Text(model.localized("每个模块是一个文件夹，打开后侧栏只显示其中的页面。")).font(.system(size:12)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns:columns,alignment:.leading,spacing:26) {
                    ForEach(present.filter { !$0.hidden || showHidden }) { module in
                        ModuleTile(module:module,count:pageCount(module)) { editing = .edit(module) }
                            .opacity(module.hidden ? 0.45 : 1)
                            .onDrag { dragging = module.id; return NSItemProvider(object:module.id as NSString) }
                            .onDrop(of:[.text],isTargeted:nil) { _ in
                                if let dragging { model.moveModule(dragging,before:module.id) }
                                dragging = nil; return true
                            }
                    }
                    Button { editing = .new } label: {
                        VStack(spacing:9) {
                            RoundedRectangle(cornerRadius:76 * 0.24,style:.continuous).strokeBorder(Color.secondary.opacity(0.35),style:StrokeStyle(lineWidth:1.5,dash:[5,4]))
                                .overlay { Image(systemName:"plus").font(.system(size:26,weight:.light)).foregroundStyle(.secondary) }
                                .frame(width:99,height:76)
                            Text(model.localized("新建模块")).font(.system(size:12)).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("newModule")
                }
                if !hidden.isEmpty {
                    Button { withAnimation(.easeInOut(duration:0.15)) { showHidden.toggle() } } label: {
                        Label(showHidden ? model.localized("收起已隐藏的模块") : model.localized("显示已隐藏的模块 (%@)",model.language.number(hidden.count)),systemImage:showHidden ? "eye.slash" : "eye")
                            .font(.system(size:11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.padding(.horizontal,48).padding(.vertical,40).frame(maxWidth:820,alignment:.leading).frame(maxWidth:.infinity)
        }
        .background(Color.canvas)
        .sheet(item:$editing) { target in ModuleEditor(target:target).environmentObject(model) }
    }
    private func pageCount(_ module: PageModule) -> Int {
        let prefix = module.folder + "/"
        return model.index?.files.filter { $0.relativePath.hasPrefix(prefix) && (module.kind == .attachments ? MediaKinds.isMedia($0.ext) : $0.ext == "md") }.count ?? 0
    }
}

struct ModuleTile: View {
    @EnvironmentObject var model: AppModel
    let module: PageModule
    let count: Int
    let edit: () -> Void
    @State private var hovering = false
    var body: some View {
        Button { model.enterModule(module.id) } label: {
            VStack(spacing:9) {
                ModuleTileIcon(icon:module.icon,color:module.color,hovering:hovering).offset(y:hovering ? -2 : 0)
                VStack(spacing:2) {
                    Text(module.name).font(.system(size:12,weight:.medium)).lineLimit(1).truncationMode(.middle)
                    Text(module.kind == .attachments ? model.language.fileCount(count) : model.language.noteCount(count)).font(.system(size:10)).foregroundStyle(.tertiary)
                }
            }.frame(maxWidth:.infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(module.folder)
        .onHover { hover in withAnimation(.easeOut(duration:0.12)) { hovering = hover } }
        .contextMenu {
            Button { model.enterModule(module.id) } label: { Label(model.localized("打开"),systemImage:"arrow.up.forward.app") }
            Button(action:edit) { Label(model.localized("编辑模块…"),systemImage:"slider.horizontal.3") }
            Button { model.setModuleHidden(module.id,!module.hidden) } label: { Label(module.hidden ? model.localized("取消隐藏") : model.localized("隐藏"),systemImage:module.hidden ? "eye" : "eye.slash") }
            Divider()
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.index!.root.appendingPathComponent(module.folder)]) } label: { Label(model.localized("在 Finder 中显示"),systemImage:"folder") }
            Button(role:.destructive) { model.removeModule(module.id) } label: { Label(model.localized("从模块中移除（保留文件夹）"),systemImage:"minus.circle") }
        }
        .accessibilityIdentifier("module-\(module.folder)")
    }
}

enum ModuleEditorTarget: Identifiable {
    case new, edit(PageModule)
    var id: String { if case .edit(let module) = self { return module.id }; return "+" }
}

/// Names a module and picks its icon and colour.
struct ModuleEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: ModuleEditorTarget
    @State private var name = ""
    @State private var icon = "sparkles"
    @State private var color = "pink"
    private var isNew: Bool { if case .new = target { return true }; return false }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:14) {
                ModuleTileIcon(icon:icon,color:color,size:52)
                VStack(alignment:.leading,spacing:4) {
                    Text(isNew ? model.localized("新建模块") : model.localized("编辑模块")).font(.system(size:17,weight:.semibold))
                    Text(isNew ? model.localized("会在页面文件夹中新建同名文件夹。") : model.localized("只改模块的显示名称，文件夹不变。")).font(.system(size:11)).foregroundStyle(.secondary)
                }
            }
            TextField(model.localized("模块名称"),text:$name).textFieldStyle(.roundedBorder).onSubmit(commit)
            Text(model.localized("图标")).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns:Array(repeating:GridItem(.fixed(34),spacing:6),count:10),spacing:6) {
                ForEach(ModuleStore.icons.filter { NSImage(systemSymbolName:$0,accessibilityDescription:nil) != nil },id:\.self) { symbol in
                    Button { icon = symbol } label: {
                        Image(systemName:symbol).font(.system(size:15)).frame(width:34,height:30)
                            .background(icon == symbol ? Color.acPink.opacity(0.18) : Color.wash,in:RoundedRectangle(cornerRadius:7))
                            .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(icon == symbol ? Color.acPink : .clear,lineWidth:1.5))
                    }.buttonStyle(.plain)
                }
            }
            Text(model.localized("颜色")).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
            HStack(spacing:10) {
                ForEach(ModuleStore.colors,id:\.self) { option in
                    Button { color = option } label: {
                        Circle().fill(ModuleStyle.tile(option)).frame(width:22,height:22)
                            .overlay(Circle().strokeBorder(Color.faint))
                            .padding(3).overlay(Circle().strokeBorder(color == option ? Color.acPink : .clear,lineWidth:2))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button(model.localized("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? model.localized("创建") : model.localized("保存"),action:commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in:.whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width:440).tint(.acPink)
        .onAppear { if case .edit(let module) = target { name = module.name; icon = module.icon; color = module.color } }
    }
    private func commit() {
        switch target {
        case .new: if model.createModule(name:name,icon:icon,color:color) { dismiss() }
        case .edit(let module): model.updateModule(module.id,name:name,icon:icon,color:color); dismiss()
        }
    }
}

/// The compact module switcher at the top of the sidebar.
struct ModuleBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let module = model.activeModule {
            HStack(spacing:8) {
                Button { withAnimation(.easeInOut(duration:0.15)) { model.enterModule(nil) } } label: {
                    Image(systemName:"chevron.left").font(.system(size:11,weight:.semibold)).frame(width:20,height:22).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("所有模块"))
                ModuleTileIcon(icon:module.icon,color:module.color,size:22,active:true)
                Text(module.name).font(.system(size:13,weight:.semibold)).lineLimit(1)
                Spacer()
                Button { model.goHome() } label: { Image(systemName:"square.grid.2x2").font(.system(size:12)).frame(width:22,height:22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("所有模块"))
            }.padding(.horizontal,14).padding(.bottom,12)
        }
    }
}

/// The sidebar's home: one row per module, opening it like an app.
struct SidebarModuleList: View {
    @EnvironmentObject var model: AppModel
    let edit: (ModuleEditorTarget) -> Void
    var body: some View {
        LazyVStack(spacing:2) {
            ForEach(model.presentModules.filter { !$0.hidden }) { module in SidebarModuleRow(module:module,edit:edit) }
            Button { edit(.new) } label: {
                HStack(spacing:10) {
                    RoundedRectangle(cornerRadius:7,style:.continuous).strokeBorder(Color.secondary.opacity(0.35),style:StrokeStyle(lineWidth:1,dash:[3,3]))
                        .overlay { Image(systemName:"plus").font(.system(size:11)) }.frame(width:34,height:26)
                    Text(model.localized("新建模块")).font(.system(size:12)); Spacer()
                }.foregroundStyle(.secondary).padding(.horizontal,8).padding(.vertical,6).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}
struct SidebarModuleRow: View {
    @EnvironmentObject var model: AppModel
    let module: PageModule
    let edit: (ModuleEditorTarget) -> Void
    @State private var hovering = false
    @State private var dropTargeted = false
    var body: some View {
        Button { withAnimation(.easeInOut(duration:0.15)) { model.enterModule(module.id) } } label: {
            HStack(spacing:10) {
                ModuleTileIcon(icon:module.icon,color:module.color,size:26,hovering:hovering)
                Text(module.name).font(.system(size:13,weight:.medium)).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength:6)
                Image(systemName:"chevron.right").font(.system(size:9,weight:.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal,8).padding(.vertical,6).contentShape(Rectangle())
            .background(dropTargeted ? Color.acPink.opacity(0.15) : hovering ? Color.wash : .clear,in:RoundedRectangle(cornerRadius:8))
        }
        .buttonStyle(.plain).help(module.folder)
        .onHover { hovering = $0 }
        .contextMenu {
            Button { model.enterModule(module.id) } label: { Label(model.localized("打开"),systemImage:"arrow.up.forward.app") }
            Button { edit(.edit(module)) } label: { Label(model.localized("编辑模块…"),systemImage:"slider.horizontal.3") }
            Button { model.setModuleHidden(module.id,true) } label: { Label(model.localized("隐藏"),systemImage:"eye.slash") }
        }
        // Dropping a page or folder on a module moves it into the module's
        // folder; files from Finder are copied there.
        .onDrop(of:SidebarDrops.types,isTargeted:$dropTargeted) { providers in
            let target = PageDropTarget(folder:module.folder)
            return SidebarDrops.perform(providers,target:target,model:model) { model.movePage($0,to:target) }
        }
        .accessibilityIdentifier("sidebar-module-\(module.folder)")
    }
}

/// What a pages module shows before a page is opened: its recent pages.
struct ModuleHomeView: View {
    @EnvironmentObject var model: AppModel
    let module: PageModule
    var body: some View {
        let prefix = module.folder + "/"
        let pages: [VaultEntry] = model.memo("pages:" + module.folder) { (model.index?.files ?? []).filter { $0.relativePath.hasPrefix(prefix) && $0.ext == "md" } }
        let recent: [VaultEntry] = model.memo("recent:" + module.folder) { Array(pages.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(12)) }
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack(spacing:16) {
                    ModuleTileIcon(icon:module.icon,color:module.color,size:64,active:true)
                    VStack(alignment:.leading,spacing:5) {
                        Text(module.name).font(.system(size:26,weight:.bold))
                        Text(model.language.noteCount(pages.count)).font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.newPageFromEditor() } label: { Label(model.localized("新建页面"),systemImage:"square.and.pencil") }.buttonStyle(.bordered)
                }
                if recent.isEmpty {
                    Text(model.localized("这个模块还没有页面，按 ⌘N 新建。")).font(.system(size:13)).foregroundStyle(.secondary).padding(.top,30)
                } else {
                    Text(model.localized("最近编辑")).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary)
                    VStack(spacing:2) {
                        ForEach(Array(recent)) { page in
                            Button { model.open(page) } label: {
                                HStack(spacing:10) {
                                    Image(systemName:"doc.text").font(.system(size:12)).foregroundStyle(Color.acPink.opacity(0.8)).frame(width:16)
                                    Text(String(page.name.dropLast(3))).font(.system(size:13)).lineLimit(1)
                                    Spacer()
                                    Text(String(page.relativePath.dropFirst(prefix.count)).components(separatedBy:"/").dropLast().joined(separator:" / ")).font(.system(size:10)).foregroundStyle(.tertiary).lineLimit(1)
                                    if let modified = page.modified { Text(model.language.modifiedDate(modified)).font(.system(size:10)).foregroundStyle(.tertiary) }
                                }.padding(.horizontal,12).padding(.vertical,9).contentShape(Rectangle())
                            }.buttonStyle(.plain).background(Color.wash,in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                }
            }.padding(.horizontal,48).padding(.vertical,40).frame(maxWidth:820,alignment:.leading).frame(maxWidth:.infinity)
        }.background(Color.canvas)
    }
}

/// The Attachments module: every image and video, with the pages that use it.
struct AttachmentsView: View {
    @EnvironmentObject var model: AppModel
    let module: PageModule
    enum Filter: String, CaseIterable, Identifiable { case all, images, videos, unused; var id: String { rawValue } }
    @State private var filter: Filter = .all
    @State private var usage: [String:[String]] = [:]
    @State private var counted = false
    private let columns = [GridItem(.adaptive(minimum:150,maximum:190),spacing:16,alignment:.top)]
    var body: some View {
        let prefix = module.folder + "/"
        let media = (model.index?.files ?? []).filter { $0.relativePath.hasPrefix(prefix) && MediaKinds.isMedia($0.ext) }
        let shown = media.filter { file in
            switch filter {
            case .all: return true
            case .images: return MediaKinds.images.contains(file.ext)
            case .videos: return MediaKinds.videos.contains(file.ext)
            case .unused: return counted && usage[file.relativePath] == nil
            }
        }
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(module.name).font(.system(size:28,weight:.bold))
                Text(model.language.fileCount(media.count) + " · " + ByteCountFormatter.string(fromByteCount:Int64(media.reduce(0) { $0 + $1.size }),countStyle:.file)).font(.system(size:12)).foregroundStyle(.secondary)
                Spacer()
                if model.modules.contains(where: { $0.id == module.id }) {
                    Button { model.setModuleHidden(module.id,!module.hidden) } label: {
                        Label(module.hidden ? model.localized("取消隐藏") : model.localized("隐藏此模块"),systemImage:module.hidden ? "eye" : "eye.slash").font(.system(size:11))
                    }.buttonStyle(.bordered).help(model.localized("隐藏后不在模块和侧栏中显示，附件照常使用。"))
                }
            }
            Text(model.localized("在页面中删掉图片或视频后，没有其他页面引用的附件会自动移到垃圾桶，15 天内可恢复。")).font(.system(size:11)).foregroundStyle(.secondary)
            SettingsSegments(options:Filter.allCases,selection:filter,title:{ title($0) }) { filter = $0 }.frame(maxWidth:360)
            ScrollView {
                LazyVGrid(columns:columns,spacing:16) {
                    ForEach(shown) { file in AttachmentCard(file:file,pages:usage[file.relativePath] ?? [],counted:counted) }
                }.padding(.bottom,20)
                if shown.isEmpty { Text(model.localized("没有找到匹配的文件")).font(.system(size:12)).foregroundStyle(.tertiary).frame(maxWidth:.infinity).padding(.top,40) }
            }
        }
        .padding(.horizontal,32).padding(.top,26).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .background(Color.canvas)
        .task(id:"\(model.index?.files.count ?? 0)-\(model.searchedPageCount)-\(module.folder)") { await countUsage() }
    }
    private func title(_ filter: Filter) -> String {
        switch filter { case .all: return model.localized("全部"); case .images: return model.localized("图片"); case .videos: return model.localized("视频"); case .unused: return model.localized("未被引用") }
    }
    private func countUsage() async {
        guard let index = model.index else { return }
        let pages = model.searchedPages, folder = module.folder
        let result = await Task.detached(priority:.utility) { AttachmentReferences.usage(pages:pages,index:index,folder:folder) }.value
        usage = result; counted = true
    }
}

struct AttachmentCard: View {
    @EnvironmentObject var model: AppModel
    let file: VaultEntry
    let pages: [String]
    let counted: Bool
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    var body: some View {
        Button { model.open(file) } label: {
            VStack(alignment:.leading,spacing:7) {
                // The thumbnail fills a fixed frame and is cut to it, whatever its shape.
                Color.wash.frame(height:118).frame(maxWidth:.infinity)
                .overlay {
                    if let thumbnail { Image(nsImage:thumbnail).resizable().scaledToFill() }
                    else { Image(systemName:MediaKinds.videos.contains(file.ext) ? "film" : "photo").font(.system(size:24,weight:.light)).foregroundStyle(.tertiary) }
                }
                .overlay { if MediaKinds.videos.contains(file.ext) { Image(systemName:"play.circle.fill").font(.system(size:26)).foregroundStyle(.white.opacity(0.9)).shadow(radius:3) } }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius:9,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:9,style:.continuous).strokeBorder(hovering ? Color.acPink.opacity(0.7) : Color.faint))
                Text(file.name).font(.system(size:11,weight:.medium)).lineLimit(1).truncationMode(.middle)
                Group {
                    if !counted { Text(" ") }
                    else if pages.isEmpty { Text(model.localized("未被引用")).foregroundStyle(Color.acPink) }
                    else { Text(pages.count == 1 ? model.localized("1 个页面引用") : model.localized("%@ 个页面引用",model.language.number(pages.count))).foregroundStyle(.secondary) }
                }.font(.system(size:10))
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(file.relativePath)
        .onHover { hovering = $0 }
        .contextMenu {
            if !pages.isEmpty {
                Menu(model.localized("引用它的页面")) {
                    ForEach(pages.sorted(),id:\.self) { path in
                        Button((path as NSString).lastPathComponent.replacingOccurrences(of:".md",with:"")) {
                            if let page = model.index?.files.first(where: { $0.relativePath == path }) { model.open(page) }
                        }
                    }
                }
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Label(model.localized("在 Finder 中显示"),systemImage:"folder") }
            Divider()
            Button(role:.destructive) { model.delete(file) } label: { Label(model.localized("移到垃圾桶"),systemImage:"trash") }
        }
        .task(id:file.relativePath) { thumbnail = await AttachmentThumbnails.image(for:file) }
    }
}

enum AttachmentThumbnails {
    private static let cache = NSCache<NSString,NSImage>()
    static func image(for file: VaultEntry) async -> NSImage? {
        let key = "\(file.url.path)|\(file.modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = cache.object(forKey:key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt:file.url,size:CGSize(width:380,height:240),scale:2,representationTypes:.thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for:request).nsImage else { return nil }
        cache.setObject(image,forKey:key)
        return image
    }
}

/// Plays a video file from the pages folder.
struct VideoPane: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating; view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url:url)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
