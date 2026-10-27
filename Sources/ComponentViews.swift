import SwiftUI
import AppKit

/// A vertical letter index like the one in Contacts. Click a letter, or press
/// and drag along the rail to run through them. Reusable: it only knows the
/// group names and the selection.
struct IndexRail: View {
    let groups: [String]
    @Binding var selection: String?
    private let rowHeight: CGFloat = 20
    var body: some View {
        VStack(spacing:0) {
            ForEach(groups,id:\.self) { group in
                let selected = group == selection
                Text(group).font(.system(size:11,weight:.semibold))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .frame(width:26,height:rowHeight)
                    .background(selected ? Color.acPink : .clear,in:RoundedRectangle(cornerRadius:6,style:.continuous))
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
            case .cardIndex: CardIndexView(title:title,folder:instance.source,initialColumns:instance.columns) { columns in
                var updated = instance; updated.columns = columns; model.updateComponent(file,updated)
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
    var saveColumns: (Int) -> Void = { _ in }
    @State private var columnCount: Int?
    @State private var group: String?
    @State private var query = ""
    @State private var notes: [String:String] = [:]
    private struct Card: Identifiable { let page: VaultEntry; let name: String; let group: String; var id: String { page.relativePath } }
    private var perRow: Int { columnCount ?? initialColumns }
    var body: some View {
        let prefix = folder + "/"
        let cards: [Card] = (model.index?.files ?? []).filter { $0.relativePath.hasPrefix(prefix) && $0.ext == "md" }.map { page in
            let name = String(page.name.dropLast(3)), first = name.prefix(1).uppercased()
            return Card(page:page,name:name,group:first.range(of:"^[A-Z]$",options:.regularExpression) != nil ? first : "#")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let groups = Array(Set(cards.map(\.group))).sorted()
        let needle = AppModel.searchFold(query.trimmingCharacters(in:.whitespaces))
        let current = group.flatMap { groups.contains($0) ? $0 : nil } ?? groups.first
        let shown: [Card] = needle.isEmpty ? cards.filter { $0.group == current } : Array(cards.filter { AppModel.searchFold($0.name).contains(needle) || AppModel.searchFold(notes[$0.id] ?? "").contains(needle) }
            .sorted { AppModel.searchFold($0.name).hasPrefix(needle) && !AppModel.searchFold($1.name).hasPrefix(needle) }.prefix(500))
        HStack(alignment:.top,spacing:18) {
            if groups.count > 1 {
                IndexRail(groups:groups,selection:Binding(get:{ needle.isEmpty ? current : nil },set:{ group = $0; query = "" })).padding(.top,92)
            }
            VStack(alignment:.leading,spacing:14) {
                HStack(alignment:.firstTextBaseline,spacing:10) {
                    Text(title).font(.system(size:28,weight:.bold))
                    Text(model.language.noteCount(cards.count)).font(.system(size:12)).foregroundStyle(.secondary)
                    Spacer()
                    // Cards per row; the cards stay square, so more per row means smaller cards.
                    HStack(spacing:2) {
                        Button { setColumns(perRow - 1) } label: { Image(systemName:"minus").frame(width:22,height:20).contentShape(Rectangle()) }
                            .disabled(perRow <= ComponentInstance.columnRange.lowerBound)
                        Label(model.language.number(perRow),systemImage:"square.grid.3x3").font(.system(size:11).monospacedDigit()).frame(minWidth:44)
                        Button { setColumns(perRow + 1) } label: { Image(systemName:"plus").frame(width:22,height:20).contentShape(Rectangle()) }
                            .disabled(perRow >= ComponentInstance.columnRange.upperBound)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,4).padding(.vertical,3)
                    .background(Color.wash,in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color.faint))
                    .help(model.localized("每行卡片数"))
                }
                HStack(spacing:8) {
                    Image(systemName:"magnifyingglass").font(.system(size:12)).foregroundStyle(.secondary)
                    TextField(model.localized("搜索"),text:$query).textFieldStyle(.plain).font(.system(size:13))
                        .onSubmit { if let first = shown.first { model.open(first.page) } }
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    Text(model.language.number(shown.count)).font(.system(size:11).monospacedDigit()).foregroundStyle(.tertiary)
                }.padding(10).background(Color.wash,in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).strokeBorder(Color.faint))
                ScrollView {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10,alignment:.top),count:perRow),spacing:10) {
                        ForEach(shown) { card in IndexCard(name:card.name,note:notes[card.id] ?? "",perRow:perRow) { model.open(card.page) } }
                    }.padding(.bottom,24)
                    if shown.isEmpty { Text(model.localized("没有找到匹配的文件")).font(.system(size:12)).foregroundStyle(.tertiary).padding(.top,40) }
                }.id((current ?? "") + "|" + needle)
            }
        }
        .padding(.horizontal,36).padding(.top,30).frame(maxWidth:1100,maxHeight:.infinity,alignment:.topLeading).frame(maxWidth:.infinity)
        .background(Color.canvas)
        .onChange(of:initialColumns) { columnCount = nil }
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
        columnCount = clamped; saveColumns(clamped)
    }
}
struct IndexCard: View {
    let name: String
    let note: String
    var perRow = ComponentInstance.defaultColumns
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action:open) {
            // A square card: the name on top, the note filling the rest.
            // Text and padding shrink with the card, so small cards stay readable.
            let compact = perRow >= 7, roomy = perRow <= 4
            VStack(alignment:.leading,spacing:compact ? 4 : 8) {
                Text(name).font(.system(size:roomy ? 17 : compact ? 13 : 15,weight:.semibold)).foregroundStyle(Color.acPink).lineLimit(2).minimumScaleFactor(0.7)
                // The note fills the rest of the square and is cut off with "…" only where it runs out of room.
                Text(note).font(.system(size:compact ? 10.5 : 12)).foregroundStyle(.secondary).lineLimit(nil).multilineTextAlignment(.leading)
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }
            .padding(compact ? 9 : 12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .aspectRatio(1,contentMode:.fit)
            .background(Color.wash,in:RoundedRectangle(cornerRadius:10,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:10,style:.continuous).strokeBorder(hovering ? Color.acPink.opacity(0.6) : Color.faint))
            .offset(y:hovering ? -1 : 0).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(name)
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
