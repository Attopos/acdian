import SwiftUI
import AppKit

/// The Card Index and its rail are drawn this much larger than the base sizes below.
private let zoom: CGFloat = 1.15

/// A vertical letter index like the one in Contacts. Click a letter, or press
/// and drag along the rail to run through them. Reusable: it only knows the
/// group names and the selection.
struct IndexRail: View {
    let groups: [String]
    @Binding var selection: String?
    /// Text shown for a group, when it differs from the group's name.
    var labels: [String:String] = [:]
    private let rowHeight: CGFloat = 20*zoom
    var body: some View {
        VStack(spacing:0) {
            ForEach(groups,id:\.self) { group in
                let selected = group == selection
                Text(labels[group] ?? group).font(.system(size:11*zoom,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .frame(width:30*zoom,height:rowHeight)
                    .background(selected ? Color.acPink : .clear,in:RoundedRectangle(cornerRadius:6*zoom,style:.continuous))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance:0).onChanged { value in
            let i = Int(value.location.y / rowHeight)
            if groups.indices.contains(i), selection != groups[i] { selection = groups[i] }
        })
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Index")
        .accessibilityValue(selection ?? "")
        .accessibilityAdjustableAction { direction in
            guard let current = selection.flatMap({ groups.firstIndex(of:$0) }) else { selection = groups.first; return }
            let next = direction == .increment ? min(groups.count - 1,current + 1) : max(0,current - 1)
            selection = groups[next]
        }
    }
}

/// Opens a component file: reads which component it is and draws it.
struct ComponentPage: View {
    @EnvironmentObject var model: AppModel
    let file: VaultEntry
    var body: some View {
        let title = (file.name as NSString).deletingPathExtension
        if let instance = ComponentStore.read(file.url) {
            switch instance.component {
            case .cardIndex: CardIndexView(title:title,folder:instance.source,initialColumns:instance.columns,initialSaved:instance.saved) { columns,saved in
                var updated = instance; updated.columns = columns; updated.saved = saved; model.updateComponent(file,updated)
            }
            }
        } else {
            VStack(spacing:12) {
                Image(systemName:"puzzlepiece.extension").font(.system(size:40,weight:.ultraLight)).foregroundStyle(Color.acPink)
                Text(model.localized("无法读取这个组件。")).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.canvas)
        }
    }
}

/// The Card Index component: every page in a folder as a card with a short
/// note, split by first letter, with search. Only the visible cards are drawn.
struct CardIndexView: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let folder: String
    var initialColumns = ComponentInstance.defaultColumns
    var initialSaved: [String] = []
    /// Writes the cards per row and the starred pages back to the component file.
    var save: (_ columns: Int, _ saved: [String]) -> Void = { _,_ in }
    @State private var columnCount: Int?
    @State private var savedList: [String]?
    @State private var group: String?
    @State private var query = ""
    @State private var notes: [String:String] = [:]
    /// `key` is the page's path inside the folder without ".md", as kept in the saved list.
    private struct Card: Identifiable { let page: VaultEntry; let name: String; let key: String; let group: String; var id: String { page.relativePath } }
    private var perRow: Int { columnCount ?? initialColumns }
    private var saved: [String] { savedList ?? initialSaved }
    /// The rail entries that show every card and the starred cards; letters never take these names.
    static let all = "\u{2217}all", starred = "\u{2217}saved"
    var body: some View {
        let prefix = folder + "/"
        // Built once per scan of the pages folder, not on every redraw.
        let cards: [Card] = model.memo("cards:" + folder) {
            (model.index?.files ?? []).filter { $0.relativePath.hasPrefix(prefix) && $0.ext == "md" }.map { page in
                let name = String(page.name.dropLast(3)), first = name.prefix(1).uppercased()
                return Card(page:page,name:name,key:String(page.relativePath.dropFirst(prefix.count).dropLast(3)),group:first.range(of:"^[A-Z]$",options:.regularExpression) != nil ? first : "#")
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // "All" and "Saved" first, then each first letter present.
        let groups = [Self.all,Self.starred] + Array(Set(cards.map(\.group))).sorted()
        let needle = AppModel.searchFold(query.trimmingCharacters(in:.whitespaces))
        // A newly opened Card Index starts on the saved cards; its tab remembers the view picked after that.
        let current = (group ?? model.frontTabCardGroup).flatMap { groups.contains($0) ? $0 : nil } ?? Self.starred
        let savedKeys = Set(saved)
        // Saved cards in the order they were starred; pages since deleted are skipped.
        let byKey: [String:Card] = current == Self.starred ? Dictionary(cards.map { ($0.key,$0) },uniquingKeysWith: { first,_ in first }) : [:]
        let starredCards: [Card] = saved.compactMap { byKey[$0] }
        let shown: [Card] = needle.isEmpty ? (current == Self.all ? cards : current == Self.starred ? starredCards : cards.filter { $0.group == current }) : Array(cards.filter { AppModel.searchFold($0.name).contains(needle) || AppModel.searchFold(notes[$0.id] ?? "").contains(needle) }
            .sorted { AppModel.searchFold($0.name).hasPrefix(needle) && !AppModel.searchFold($1.name).hasPrefix(needle) }.prefix(500))
        HStack(alignment:.top,spacing:18*zoom) {
            if !cards.isEmpty {
                IndexRail(groups:groups,selection:Binding(get:{ needle.isEmpty ? current : nil },set:{ group = $0; model.frontTabCardGroup = $0; query = "" }),labels:[Self.all:model.localized("全部"),Self.starred:"★"]).padding(.top,92*zoom)
                    .help(model.localized("★ 是收藏的卡片，按收藏先后排列"))
            }
            VStack(alignment:.leading,spacing:14*zoom) {
                HStack(alignment:.firstTextBaseline,spacing:10*zoom) {
                    Text(title).font(.system(size:28*zoom,weight:.bold))
                    Spacer()
                    // Cards per row; the cards stay square, so more per row means smaller cards.
                    HStack(spacing:2*zoom) {
                        Button { setColumns(perRow - 1) } label: { Image(systemName:"minus").frame(width:22*zoom,height:20*zoom).contentShape(Rectangle()) }
                            .disabled(perRow <= ComponentInstance.columnRange.lowerBound)
                        Label(model.language.number(perRow),systemImage:"square.grid.3x3").font(.system(size:11*zoom).monospacedDigit()).frame(minWidth:44*zoom)
                        Button { setColumns(perRow + 1) } label: { Image(systemName:"plus").frame(width:22*zoom,height:20*zoom).contentShape(Rectangle()) }
                            .disabled(perRow >= ComponentInstance.columnRange.upperBound)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,4*zoom).padding(.vertical,3*zoom)
                    .background(Color.wash,in:RoundedRectangle(cornerRadius:7*zoom)).overlay(RoundedRectangle(cornerRadius:7*zoom).strokeBorder(Color.faint))
                    .help(model.localized("每行卡片数"))
                }
                HStack(spacing:8*zoom) {
                    Image(systemName:"magnifyingglass").font(.system(size:12*zoom)).foregroundStyle(.secondary)
                    TextField(model.localized("搜索"),text:$query).textFieldStyle(.plain).font(.system(size:13*zoom))
                        .onSubmit { if let first = shown.first { model.open(first.page) } }
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(10*zoom).background(Color.wash,in:RoundedRectangle(cornerRadius:9*zoom)).overlay(RoundedRectangle(cornerRadius:9*zoom).strokeBorder(Color.faint))
                ScrollView {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10*zoom,alignment:.top),count:perRow),spacing:10*zoom) {
                        ForEach(shown) { card in
                            IndexCard(name:card.name,note:notes[card.id] ?? "",perRow:perRow,saved:savedKeys.contains(card.key),toggleSaved:{ toggleSaved(card.key) }) { model.open(card.page) }
                        }
                    }.padding(.bottom,24*zoom)
                    if shown.isEmpty {
                        Text(model.localized(needle.isEmpty && current == Self.starred ? "还没有收藏。点卡片右上角的星标收藏。" : "没有找到匹配的文件")).font(.system(size:12*zoom)).foregroundStyle(.tertiary).padding(.top,40*zoom)
                    }
                }.id(current + "|" + needle)
            }
        }
        .padding(.horizontal,36*zoom).padding(.top,30*zoom).frame(maxWidth:1100*zoom,maxHeight:.infinity,alignment:.topLeading).frame(maxWidth:.infinity)
        .background(Color.canvas)
        .onChange(of:initialColumns) { columnCount = nil }
        .onChange(of:initialSaved) { savedList = nil }
        .task(id:"\(folder)-\(model.searchedPageCount)") {
            let pages = model.searchedPages.filter { $0.path.hasPrefix(prefix) }
            notes = await Task.detached(priority:.userInitiated) { Dictionary(pages.map { ($0.path,ComponentStore.cardNote($0.text)) },uniquingKeysWith: { first,_ in first }) }.value
        }
    }
}
extension CardIndexView {
    fileprivate func setColumns(_ value: Int) {
        let clamped = min(max(value,ComponentInstance.columnRange.lowerBound),ComponentInstance.columnRange.upperBound)
        guard clamped != perRow else { return }
        columnCount = clamped; save(clamped,saved)
    }
    fileprivate func toggleSaved(_ key: String) {
        let updated = ComponentInstance.toggled(key,in:saved)
        savedList = updated; save(perRow,updated)
    }
}
struct IndexCard: View {
    let name: String
    let note: String
    var perRow = ComponentInstance.defaultColumns
    var saved = false
    var toggleSaved: () -> Void = {}
    let open: () -> Void
    @State private var hovering = false
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let compact = perRow >= 7
        ZStack(alignment:.topTrailing) {
            card
            // The star sits over the card, not inside its button, so it gets its own clicks.
            Button(action:toggleSaved) {
                Image(systemName:saved ? "star.fill" : "star").font(.system(size:(compact ? 11 : 13)*zoom,weight:.semibold))
                    .foregroundStyle(saved ? Color.acPink : Color.secondary.opacity(hovering ? 0.9 : 0.35))
                    .frame(width:(compact ? 22 : 26)*zoom,height:(compact ? 22 : 26)*zoom).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding((compact ? 3 : 5)*zoom)
            .help(model.localized(saved ? "取消收藏" : "收藏"))
            .accessibilityLabel(model.localized(saved ? "取消收藏" : "收藏"))
        }
        .offset(y:hovering ? -1 : 0).onHover { hovering = $0 }
    }
    private var card: some View {
        Button(action:open) {
            // A square card: the name on top, the note filling the rest.
            // Text and padding shrink with the card, so small cards stay readable.
            let compact = perRow >= 7, roomy = perRow <= 4
            VStack(alignment:.leading,spacing:(compact ? 4 : 8)*zoom) {
                Text(name).font(.system(size:(roomy ? 23 : compact ? 16 : 19)*zoom,weight:.bold)).foregroundStyle(Color.acPink).lineLimit(2).minimumScaleFactor(0.7)
                    .padding(.trailing,(compact ? 16 : 20)*zoom)
                // The note fills the rest of the square and is cut off with "…" only where it runs out of room.
                Text(note).font(.system(size:(compact ? 10.5 : 12)*zoom)).foregroundStyle(.secondary).lineLimit(nil).multilineTextAlignment(.leading)
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
            .padding((compact ? 9 : 12)*zoom).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .aspectRatio(1,contentMode:.fit)
            .background(Color.wash,in:RoundedRectangle(cornerRadius:10*zoom,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:10*zoom,style:.continuous).strokeBorder(hovering ? Color.acPink.opacity(0.6) : Color.faint))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(name)
    }
}

/// Lists the components the app offers and the ones placed in pages.
struct ComponentMarketView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding: ComponentKind?
    private let columns = [GridItem(.adaptive(minimum:240,maximum:320),spacing:16,alignment:.top)]
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:6) {
                    Text(model.localized("组件")).font(.system(size:28,weight:.bold))
                    Text(model.localized("组件是 ACdian 自带的界面，像页面一样放进模块里，打开后直接使用，不是可编辑的正文。")).font(.system(size:12)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns:columns,alignment:.leading,spacing:16) {
                    ForEach(ComponentKind.allCases) { kind in
                        VStack(alignment:.leading,spacing:12) {
                            HStack(spacing:12) {
                                ModuleTileIcon(icon:kind.icon,color:kind.color,size:44)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(model.localized(kind.title)).font(.system(size:15,weight:.semibold))
                                    let count = model.componentInstances.filter { $0.instance.component == kind }.count
                                    Text(count == 0 ? model.localized("未使用") : model.localized("使用中 · %@",model.language.number(count))).font(.system(size:11)).foregroundStyle(count == 0 ? Color.secondary : Color.acPink)
                                }
                            }
                            Text(model.localized(kind.summary)).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            Button { adding = kind } label: { Label(model.localized("添加到模块…"),systemImage:"plus") }.buttonStyle(.bordered)
                        }
                        .padding(16).frame(maxWidth:.infinity,alignment:.leading)
                        .background(Color.wash,in:RoundedRectangle(cornerRadius:12,style:.continuous))
                        .overlay(RoundedRectangle(cornerRadius:12,style:.continuous).strokeBorder(Color.faint))
                    }
                }
                let placed = model.componentInstances
                if !placed.isEmpty {
                    Text(model.localized("已添加")).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary).padding(.top,6)
                    VStack(spacing:4) {
                        ForEach(placed,id:\.file.relativePath) { item in
                            HStack(spacing:12) {
                                ModuleTileIcon(icon:item.instance.component.icon,color:item.instance.component.color,size:26)
                                VStack(alignment:.leading,spacing:2) {
                                    Text((item.file.name as NSString).deletingPathExtension).font(.system(size:13,weight:.medium))
                                    Text(model.localized(item.instance.component.title) + " · " + item.instance.source).font(.system(size:10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button(model.localized("打开")) { model.open(item.file) }.buttonStyle(.bordered)
                                Button { model.delete(item.file) } label: { Image(systemName:"trash") }.buttonStyle(.borderless).help(model.localized("移到垃圾桶"))
                            }.padding(.horizontal,12).padding(.vertical,8).background(Color.wash,in:RoundedRectangle(cornerRadius:9))
                        }
                    }
                }
            }.padding(.horizontal,40).padding(.vertical,36).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity)
        }
        .background(Color.canvas)
        .sheet(item:$adding) { kind in AddComponentSheet(kind:kind).environmentObject(model) }
    }
}

/// Names a new component and picks where it goes and which folder it shows.
struct AddComponentSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: ComponentKind
    @State private var name = ""
    @State private var place = ""
    @State private var source = ""
    @State private var hideSource = false
    var body: some View {
        let folders = allFolders()
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:12) {
                ModuleTileIcon(icon:kind.icon,color:kind.color,size:44)
                Text(model.localized("添加 %@",model.localized(kind.title))).font(.system(size:17,weight:.semibold))
            }
            TextField(model.localized("名称"),text:$name).textFieldStyle(.roundedBorder)
            Picker(model.localized("放在"),selection:$place) {
                Text(model.localized("顶层")).tag("")
                ForEach(folders,id:\.self) { Text($0).tag($0) }
            }
            Picker(model.localized("显示的文件夹"),selection:$source) {
                ForEach(folders,id:\.self) { Text($0).tag($0) }
            }
            if kind.hidesSourceByDefault || hideSource {
                Toggle(model.localized("在侧栏中隐藏这个文件夹"),isOn:$hideSource)
            }
            HStack {
                Spacer()
                Button(model.localized("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.localized("添加")) {
                    if model.createComponent(kind,name:name,in:place,source:source,hideSource:hideSource) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in:.whitespaces).isEmpty || source.isEmpty)
            }
        }
        .padding(22).frame(width:480).tint(.acPink)
        .onAppear {
            name = model.localized(kind.title); hideSource = kind.hidesSourceByDefault
            place = model.activeModule?.folder ?? model.presentModules.first?.folder ?? ""
            source = folders.first(where: { $0.hasPrefix(place + "/") }) ?? place
        }
    }
    private func allFolders() -> [String] {
        var list: [String] = []
        func walk(_ entries: [VaultEntry]) { for entry in entries where entry.isDirectory { list.append(entry.relativePath); walk(entry.children ?? []) } }
        walk(model.index?.entries ?? [])
        return list
    }
}
