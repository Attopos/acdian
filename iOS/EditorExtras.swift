import SwiftUI

/// Names a module and picks its icon and colour, as on the Mac.
struct ModuleSheet: View {
    @ObservedObject var model: AppModel
    let module: PageModule?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "sparkles"
    @State private var color = "pink"
    var body: some View {
        NavigationStack {
            Form {
                Section { HStack { Spacer(); ModuleTileIcon(icon:icon,color:color,size:56); Spacer() } }.listRowBackground(Color.clear)
                Section { TextField(model.localized("模块名称"),text:$name).accessibilityIdentifier("moduleName") }
                Section(model.localized("图标")) {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:6),spacing:10) {
                        ForEach(ModuleStore.icons.filter { UIImage(systemName:$0) != nil },id:\.self) { symbol in
                            Image(systemName:symbol).font(.title3).frame(width:40,height:36)
                                .background(icon == symbol ? Color.acPink.opacity(0.18) : Color.wash,in:RoundedRectangle(cornerRadius:8))
                                .onTapGesture { icon = symbol }
                        }
                    }
                }
                Section(model.localized("颜色")) {
                    HStack { ForEach(ModuleStore.colors,id:\.self) { option in
                        Circle().fill(ModuleStyle.tile(option)).frame(width:26,height:26).padding(3)
                            .overlay(Circle().strokeBorder(color == option ? Color.acPink : .clear,lineWidth:2)).onTapGesture { color = option }
                    } }
                }
            }
            .navigationTitle(module == nil ? model.localized("新建模块") : model.localized("编辑模块")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(model.localized("取消")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(module == nil ? model.localized("创建") : model.localized("保存")) {
                        if let module { model.updateModule(module.id,name:name,icon:icon,color:color); dismiss() }
                        else if model.createModule(name:name,icon:icon,color:color) { dismiss() }
                    }.disabled(name.trimmingCharacters(in:.whitespaces).isEmpty).accessibilityIdentifier("moduleDone")
                }
            }
        }.onAppear { if let module { name = module.name; icon = module.icon; color = module.color } }
    }
}

/// Adds a Card Index showing a folder, placed beside it.
struct CardIndexSheet: View {
    @ObservedObject var model: AppModel
    let folder: VaultEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hideSource = true
    var body: some View {
        NavigationStack {
            Form {
                TextField(model.localized("名称"),text:$name)
                LabeledContent(model.localized("显示的文件夹"),value:folder.relativePath)
                Toggle(model.localized("在侧栏中隐藏这个文件夹"),isOn:$hideSource)
            }
            .navigationTitle(model.localized("添加 %@",model.localized("卡片索引"))).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(model.localized("取消")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(model.localized("添加")) {
                        if model.createComponent(.cardIndex,name:name,in:(folder.relativePath as NSString).deletingLastPathComponent,source:folder.relativePath,hideSource:hideSource) { dismiss() }
                    }.disabled(name.trimmingCharacters(in:.whitespaces).isEmpty).accessibilityIdentifier("cardIndexDone")
                }
            }
        }.onAppear { name = folder.name }
    }
}

/// The Card Index with its controls: star cards, change cards per row.
struct EditableCardIndex: View {
    @ObservedObject var model: AppModel
    let file: VaultEntry
    @State private var instance: ComponentInstance?
    @State private var group: String?
    @State private var query = ""
    @State private var notes: [String:String] = [:]
    private static let all = "\u{2217}all", starred = "\u{2217}saved"
    private struct Card: Identifiable { let page: VaultEntry; let name: String; let key: String; let group: String; var id: String { page.relativePath } }
    var body: some View {
        if let instance {
            let prefix = instance.source + "/"
            let cards = (model.index?.files ?? []).filter { $0.relativePath.hasPrefix(prefix) && $0.ext == "md" }.map { page in
                let name = String(page.name.dropLast(3)), first = name.prefix(1).uppercased()
                return Card(page:page,name:name,key:String(page.relativePath.dropFirst(prefix.count).dropLast(3)),group:first.range(of:"^[A-Z]$",options:.regularExpression) != nil ? first : "#")
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let groups = [Self.all,Self.starred] + Array(Set(cards.map(\.group))).sorted()
            let current = group.flatMap { groups.contains($0) ? $0 : nil } ?? Self.starred
            let byKey = Dictionary(cards.map { ($0.key,$0) },uniquingKeysWith: { first,_ in first })
            let needle = AppModel.searchFold(query.trimmingCharacters(in:.whitespaces))
            let shown: [Card] = !needle.isEmpty ? cards.filter { AppModel.searchFold($0.name).contains(needle) || AppModel.searchFold(notes[$0.id] ?? "").contains(needle) }
                : current == Self.all ? cards : current == Self.starred ? instance.saved.compactMap { byKey[$0] } : cards.filter { $0.group == current }
            let perRow = min(max(instance.columns,2),6)
            VStack(spacing:10) {
                HStack {
                    Picker("",selection:Binding(get:{ current },set:{ group = $0 })) {
                        ForEach(groups,id:\.self) { Text($0 == Self.all ? model.localized("全部") : $0 == Self.starred ? "★" : $0).tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("cardGroup")
                    TextField(model.localized("搜索"),text:$query).textFieldStyle(.roundedBorder).frame(maxWidth:260)
                    Spacer()
                    Stepper(model.localized("每行卡片数") + " " + model.language.number(perRow),value:Binding(get:{ perRow },set:{ change { $0.columns = $1 }(min(max($0,2),6)) }),in:2...6).fixedSize().accessibilityIdentifier("cardColumns")
                }.padding(.horizontal,16).padding(.top,10)
                ScrollView {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10,alignment:.top),count:perRow),spacing:10) {
                        ForEach(shown) { card in
                            let saved = instance.saved.contains(card.key)
                            ZStack(alignment:.topTrailing) {
                                Button { model.open(card.page) } label: {
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(card.name).font(.system(size:19,weight:.bold)).foregroundStyle(Color.acPink).lineLimit(2).minimumScaleFactor(0.7).padding(.trailing,22)
                                        Text(notes[card.id] ?? "").font(.footnote).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                                    }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).aspectRatio(1,contentMode:.fit)
                                    .background(Color.wash,in:RoundedRectangle(cornerRadius:12,style:.continuous)).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { change { instance,_ in instance.saved = ComponentInstance.toggled(card.key,in:instance.saved) }(0) } label: {
                                    Image(systemName:saved ? "star.fill" : "star").foregroundStyle(saved ? Color.acPink : Color.secondary).frame(width:34,height:34)
                                }.buttonStyle(.plain).accessibilityIdentifier("star-" + card.name)
                            }
                        }
                    }.padding(.horizontal,16).padding(.bottom,24)
                    if shown.isEmpty { Text(model.localized(current == Self.starred && needle.isEmpty ? "还没有收藏。点卡片右上角的星标收藏。" : "没有找到匹配的文件")).font(.footnote).foregroundStyle(.tertiary).padding(.top,40) }
                }
            }
            .background(Color.canvas)
            .navigationTitle((file.name as NSString).deletingPathExtension)
            .task(id:"\(instance.source)-\(model.searchedPageCount)") {
                let pages = model.searchedPages.filter { $0.path.hasPrefix(prefix) }
                notes = await Task.detached { Dictionary(pages.map { ($0.path,ComponentStore.cardNote($0.text)) },uniquingKeysWith: { first,_ in first }) }.value
            }
        } else {
            ProgressView().task(id:file.id) { instance = try? JSONDecoder().decode(ComponentInstance.self,from:await ReaderFiles.data(file.url)) }
        }
    }
    /// Applies a change to the component and writes it back through the shared model.
    private func change(_ edit: @escaping (inout ComponentInstance, Int) -> Void) -> (Int) -> Void {
        { value in
            guard var updated = instance else { return }
            edit(&updated,value); instance = updated
            model.updateComponent(file,updated)
        }
    }
}

/// Every picture and video in the Attachments module, with how many pages use it.
struct AttachmentsGrid: View {
    @ObservedObject var model: AppModel
    let module: PageModule
    @State private var usage: [String:[String]] = [:]
    @State private var unusedOnly = false
    var body: some View {
        let media = (model.index?.files ?? []).filter { $0.relativePath.hasPrefix(module.folder + "/") && MediaKinds.isMedia($0.ext) }
        let shown = unusedOnly ? media.filter { model.allPagesSearched && usage[$0.relativePath] == nil } : media
        VStack(alignment:.leading,spacing:10) {
            Picker("",selection:$unusedOnly) { Text(model.localized("全部")).tag(false); Text(model.localized("未使用")).tag(true) }.pickerStyle(.segmented).frame(maxWidth:280).padding(.horizontal,16).padding(.top,10)
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:150,maximum:200),spacing:14)],spacing:14) {
                    ForEach(shown) { file in
                        Button { model.open(file) } label: {
                            VStack(alignment:.leading,spacing:6) {
                                Thumbnail(file:file).frame(height:120).frame(maxWidth:.infinity).clipped().background(Color.wash).clipShape(RoundedRectangle(cornerRadius:10,style:.continuous))
                                Text(file.name).font(.caption).lineLimit(1).foregroundStyle(Color.ink)
                                // As on the Mac: no counts, only a mark on pictures no page uses.
                                Text(model.allPagesSearched && usage[file.relativePath] == nil ? model.localized("未被引用") : " ").font(.caption2).foregroundStyle(Color.acPink)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(16)
            }
        }
        .background(Color.canvas).navigationTitle(module.name)
        .task(id:"\(module.folder)-\(model.searchedPageCount)") {
            guard let index = model.index else { return }
            let pages = model.searchedPages, folder = module.folder
            usage = await Task.detached { AttachmentReferences.usage(pages:pages,index:index,folder:folder) }.value
        }
    }
}

private struct Thumbnail: View {
    let file: VaultEntry
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFill() }
            else { Image(systemName:MediaKinds.videos.contains(file.ext) ? "film" : "photo").font(.title).foregroundStyle(.secondary) }
        }.task(id:file.id) {
            guard MediaKinds.images.contains(file.ext), let data = try? await ReaderFiles.data(file.url) else { return }
            image = await Task.detached { UIImage(data:data)?.preparingThumbnail(of:CGSize(width:400,height:400)) }.value
        }
    }
}

/// The page's headings; tapping one scrolls the editor there.
struct OutlineList: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    var body: some View {
        List {
            ForEach(Array(model.headings.enumerated()),id:\.offset) { index,heading in
                Button { model.anchor = heading.title; model.activeHeading = index; done() } label: {
                    Text(heading.title).padding(.leading,CGFloat(max(0,heading.level - 1)) * 14).foregroundStyle(index == model.activeHeading ? Color.acPink : Color.ink)
                }
            }
        }.frame(minWidth:280,minHeight:320).overlay { if model.headings.isEmpty { Text(model.localized("目录")).foregroundStyle(.tertiary) } }
    }
}

/// Language, appearance, icon, and where the pages are kept.
struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var icon = UIApplication.shared.alternateIconName == nil ? AppIconStyle.pink : .black
    var body: some View {
        NavigationStack {
            Form {
                Section(model.localized("语言")) {
                    Picker(model.localized("语言"),selection:$model.language) { ForEach(AppLanguage.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
                }
                Section(model.localized("外观")) {
                    Picker(model.localized("外观"),selection:$model.appearance) { ForEach(AppAppearance.allCases) { Text(model.localized($0.title)).tag($0) } }.pickerStyle(.segmented)
                }
                Section(model.localized("图标")) {
                    Picker(model.localized("图标"),selection:$icon) { ForEach(AppIconStyle.allCases) { Text(model.localized($0.title)).tag($0) } }.pickerStyle(.segmented)
                        .onChange(of:icon) { _,style in UIApplication.shared.setAlternateIconName(style == .black ? "AppIconBlack" : nil) }
                }
                Section("iCloud") {
                    let path = model.index?.root.path ?? ""
                    Label(path.contains("/Mobile Documents/") ? "iCloud Drive › ACdian" : model.localized("iCloud 不可用，正在显示本机文件夹。"),systemImage:path.contains("/Mobile Documents/") ? "icloud" : "icloud.slash")
                }
            }
            .navigationTitle(model.localized("设置")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button(model.localized("好")) { dismiss() } } }
        }
    }
}
