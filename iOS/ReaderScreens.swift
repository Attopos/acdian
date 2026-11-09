import SwiftUI

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
    static func glyph(_ name: String) -> LinearGradient {
        let base = tile(name), second: Color = name == "black" ? .acPink : base.opacity(0.62)
        return LinearGradient(colors:[base,second],startPoint:.topLeading,endPoint:.bottomTrailing)
    }
    static let frost = Color.adaptive(dark:UIColor.white.withAlphaComponent(0.07),light:UIColor(red:0.93,green:0.92,blue:0.95,alpha:1))
    static let frostEdge = Color.adaptive(dark:UIColor.white.withAlphaComponent(0.10),light:UIColor.black.withAlphaComponent(0.07))
    static func symbol(_ name: String) -> String { UIImage(systemName:name) != nil ? name : "folder" }
}

struct ModuleTileIcon: View {
    let icon: String
    let color: String
    var size: CGFloat = 76
    var body: some View {
        let corner = size * 0.24
        ZStack {
            RoundedRectangle(cornerRadius:corner,style:.continuous).fill(ModuleStyle.frost)
            RoundedRectangle(cornerRadius:corner,style:.continuous).strokeBorder(ModuleStyle.frostEdge,lineWidth:1.5)
            Image(systemName:ModuleStyle.symbol(icon)).font(.system(size:size * 0.38,weight:.medium)).foregroundStyle(ModuleStyle.glyph(color))
        }.frame(width:(size * 1.3).rounded(),height:size)
    }
}

/// The home screen: every module as a tile, then the pages outside any module.
struct LauncherScreen: View {
    @EnvironmentObject private var store: ReaderStore
    @EnvironmentObject private var router: ReaderRouter
    @State private var query = ""
    @State private var showHidden = false
    private let columns = [GridItem(.adaptive(minimum:104,maximum:140),spacing:14,alignment:.top)]
    var body: some View {
        Group {
            if !query.isEmpty { SearchResults(query:query,module:nil) }
            else if store.index == nil { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas) }
            else { grid }
        }
        .navigationTitle(store.localized("模块"))
        .searchable(text:$query,prompt:store.localized("搜索"))
        .autocorrectionDisabled()
    }
    private var grid: some View {
        let present = store.presentModules, hidden = present.filter(\.hidden)
        let loose = store.visible(store.index?.entries ?? []).filter { !$0.isDirectory }
        return ScrollView {
            VStack(alignment:.leading,spacing:24) {
                if !store.usesICloud {
                    Label(store.localized("iCloud 不可用，正在显示本机文件夹。"),systemImage:"icloud.slash").font(.footnote).foregroundStyle(.secondary)
                }
                LazyVGrid(columns:columns,spacing:22) {
                    ForEach(present.filter { !$0.hidden || showHidden }) { module in
                        NavigationLink(value:Route.folder(module.folder)) {
                            VStack(spacing:8) {
                                ModuleTileIcon(icon:module.icon,color:module.color)
                                Text(module.name).font(.footnote.weight(.medium)).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.ink)
                                let count = store.pageCount(module)
                                Text(module.kind == .attachments ? store.language.fileCount(count) : store.language.noteCount(count)).font(.caption2).foregroundStyle(.tertiary)
                            }.frame(maxWidth:.infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain).opacity(module.hidden ? 0.45 : 1)
                    }
                }
                if !hidden.isEmpty {
                    Button { withAnimation(.easeInOut(duration:0.15)) { showHidden.toggle() } } label: {
                        Label(showHidden ? store.localized("收起已隐藏的模块") : store.localized("显示已隐藏的模块 (%@)",store.language.number(hidden.count)),systemImage:showHidden ? "eye.slash" : "eye").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if !loose.isEmpty {
                    VStack(spacing:0) {
                        ForEach(loose) { file in
                            EntryRow(entry:file).padding(.vertical,11)
                            if file.id != loose.last?.id { Divider() }
                        }
                    }.padding(.horizontal,14).background(Color.wash,in:RoundedRectangle(cornerRadius:12,style:.continuous))
                }
                if present.isEmpty && loose.isEmpty {
                    ReaderEmptyState(icon:"tray",message:store.localized("没有找到匹配的文件")).frame(height:260)
                }
            }.padding(.horizontal,20).padding(.vertical,12).frame(maxWidth:820).frame(maxWidth:.infinity)
        }
        .background(Color.canvas)
        .refreshable { await store.reload() }
    }
}

private func symbol(for entry: VaultEntry) -> String {
    if entry.isDirectory { return "folder" }
    if entry.ext == "pdf" { return "doc.richtext" }
    if MediaKinds.images.contains(entry.ext) { return "photo" }
    if MediaKinds.videos.contains(entry.ext) { return "film" }
    if entry.ext == ComponentStore.fileExtension { return "rectangle.grid.2x2" }
    return "doc.text"
}

/// One row: a folder pushes its list, a file opens in the page column.
struct EntryRow: View {
    @EnvironmentObject private var store: ReaderStore
    @EnvironmentObject private var router: ReaderRouter
    let entry: VaultEntry
    private var name: String { entry.isDirectory || !["md","markdown",ComponentStore.fileExtension].contains(entry.ext) ? entry.name : (entry.name as NSString).deletingPathExtension }
    private var label: some View {
        HStack(spacing:11) {
            Image(systemName:symbol(for:entry)).foregroundStyle(Color.acPink).frame(width:24)
            Text(name).lineLimit(2).foregroundStyle(Color.ink)
            Spacer(minLength:6)
            if store.remote.contains(entry.relativePath) { Image(systemName:"icloud.and.arrow.down").font(.footnote).foregroundStyle(.secondary) }
        }.contentShape(Rectangle())
    }
    var body: some View {
        if entry.isDirectory { NavigationLink(value:Route.folder(entry.relativePath)) { label }.buttonStyle(.plain) }
        else { Button { router.openFromList(entry.relativePath) } label: { label }.buttonStyle(.plain) }
    }
}

struct FolderScreen: View {
    @EnvironmentObject private var store: ReaderStore
    let folder: VaultEntry
    @State private var query = ""
    private var moduleFolder: String { String(folder.relativePath.split(separator:"/")[0]) }
    private var title: String { store.modules.first { $0.folder == folder.relativePath }?.name ?? folder.name }
    var body: some View {
        Group {
            if !query.isEmpty { SearchResults(query:query,module:moduleFolder) }
            else {
                List(store.visible(folder.children ?? [])) { entry in
                    EntryRow(entry:entry).listRowBackground(Color.canvas).listRowSeparatorTint(Color.faint)
                }
                .listStyle(.plain).readerBackground()
                .refreshable { await store.reload() }
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .searchable(text:$query,prompt:store.localized("搜索"))
        .autocorrectionDisabled()
    }
}

struct SearchResults: View {
    @EnvironmentObject private var store: ReaderStore
    let query: String
    let module: String?
    var body: some View {
        let results = store.search(query,inModule:module)
        if results.isEmpty { ReaderEmptyState(icon:"magnifyingglass",message:store.localized("没有找到匹配的文件")) }
        else {
            List(results) { file in
                VStack(alignment:.leading,spacing:2) {
                    EntryRow(entry:file)
                    let parent = (file.relativePath as NSString).deletingLastPathComponent
                    if !parent.isEmpty { Text(parent).font(.caption2).foregroundStyle(.tertiary).padding(.leading,35).lineLimit(1).truncationMode(.middle) }
                }.listRowBackground(Color.canvas).listRowSeparatorTint(Color.faint)
            }.listStyle(.plain).readerBackground()
        }
    }
}

/// The Card Index, read-only: every page in a folder as a square card.
struct CardIndexScreen: View {
    @EnvironmentObject private var store: ReaderStore
    @EnvironmentObject private var router: ReaderRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    let file: VaultEntry
    let instance: ComponentInstance
    @State private var group: String?
    @State private var query = ""
    private static let all = "\u{2217}all", starred = "\u{2217}saved"
    private struct Card: Identifiable { let page: VaultEntry; let name: String; let key: String; let group: String; var id: String { page.relativePath } }
    private var cards: [Card] {
        let prefix = instance.source + "/"
        return (store.index?.files ?? []).filter { $0.relativePath.hasPrefix(prefix) && $0.ext == "md" }.map { page in
            let name = String(page.name.dropLast(3)), first = name.prefix(1).uppercased()
            return Card(page:page,name:name,key:String(page.relativePath.dropFirst(prefix.count).dropLast(3)),group:first.range(of:"^[A-Z]$",options:.regularExpression) != nil ? first : "#")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        let cards = self.cards
        let saved = instance.saved.compactMap { key in cards.first { $0.key == key } }
        let groups = [Self.all] + (saved.isEmpty ? [] : [Self.starred]) + Array(Set(cards.map(\.group))).sorted()
        // Nothing can be starred here, so an empty "Saved" view would be a dead end.
        let current = group.flatMap { groups.contains($0) ? $0 : nil } ?? (saved.isEmpty ? Self.all : Self.starred)
        let needle = ReaderStore.searchFold(query.trimmingCharacters(in:.whitespaces))
        let shown: [Card] = !needle.isEmpty ? cards.filter { ReaderStore.searchFold($0.name).contains(needle) || ReaderStore.searchFold(store.notes[$0.id] ?? "").contains(needle) }
            : current == Self.all ? cards : current == Self.starred ? saved : cards.filter { $0.group == current }
        let columns = Array(repeating:GridItem(.flexible(),spacing:10,alignment:.top),count:sizeClass == .compact ? 2 : 3)
        HStack(alignment:.top,spacing:6) {
            ScrollView {
                LazyVGrid(columns:columns,spacing:10) {
                    ForEach(shown) { card in
                        Button { router.push(card.page.relativePath,fragment:"") } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Text(card.name).font(.system(size:20,weight:.bold)).foregroundStyle(Color.acPink).lineLimit(2).minimumScaleFactor(0.7)
                                Text(store.notes[card.id] ?? "").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                            }
                            .padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).aspectRatio(1,contentMode:.fit)
                            .background(Color.wash,in:RoundedRectangle(cornerRadius:12,style:.continuous))
                            .overlay(RoundedRectangle(cornerRadius:12,style:.continuous).strokeBorder(Color.faint))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.leading,14).padding(.vertical,8)
                if shown.isEmpty { Text(store.localized("没有找到匹配的文件")).font(.footnote).foregroundStyle(.tertiary).padding(.top,40) }
            }.frame(maxWidth:.infinity).refreshable { await store.reload() }
            if needle.isEmpty && cards.count > 0 {
                CardRail(groups:groups,selection:current,labels:[Self.all:store.localized("全部"),Self.starred:"★"]) { group = $0 }.padding(.trailing,2)
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas)
        .navigationTitle((file.name as NSString).deletingPathExtension).navigationBarTitleDisplayMode(.inline)
        .searchable(text:$query,prompt:store.localized("搜索"))
        .autocorrectionDisabled()
    }
}

/// The letter strip beside the cards: tap a letter or run a finger along it.
private struct CardRail: View {
    let groups: [String]
    let selection: String
    let labels: [String:String]
    let select: (String) -> Void
    var body: some View {
        GeometryReader { geometry in
            let row = min(22,(geometry.size.height - 12) / CGFloat(max(groups.count,1)))
            VStack(spacing:0) {
                ForEach(groups,id:\.self) { group in
                    Text(labels[group] ?? group).font(.system(size:10,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(group == selection ? Color.white : Color.secondary)
                        .frame(width:24,height:row)
                        .background(group == selection ? Color.acPink : .clear,in:RoundedRectangle(cornerRadius:5,style:.continuous))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                let i = Int(value.location.y / row)
                if groups.indices.contains(i), groups[i] != selection { select(groups[i]) }
            })
        }.frame(width:24).padding(.vertical,8)
    }
}
