import SwiftUI

enum FacetStyle {
    static let rowHeight: CGFloat = 25
    static func tagColor(_ tag: String) -> Color {
        switch tag.uppercased() {
        case "ENG": return ModuleStyle.tile("sky")
        case "DES": return .acPink
        case "BIZ": return ModuleStyle.tile("amber")
        case "CS": return ModuleStyle.tile("teal")
        case "ARTICLE": return ModuleStyle.tile("plum")
        default: return ModuleStyle.tile("graphite")
        }
    }
}

struct FacetRowBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal,8).frame(height:FacetStyle.rowHeight)
            .background(selected ? Color.canvas : hovering ? Color.wash : .clear)
            .overlay { if selected { Rectangle().strokeBorder(Color.faint,lineWidth:1) } }
            .overlay(alignment:.leading) { if selected { Rectangle().fill(Color.acPink).frame(width:2) } }
            .contentShape(Rectangle())
    }
}

struct FacetRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false
    var body: some View {
        Button(action:action) {
            HStack(spacing:8) { label; Spacer(minLength:0) }
                .font(.system(size:12.5,weight:selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .modifier(FacetRowBackground(selected:selected,hovering:hovering))
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

struct TagChip: View {
    let tag: String
    var body: some View {
        Text(tag).font(.system(size:10.5,weight:.bold)).foregroundStyle(FacetStyle.tagColor(tag))
            .padding(.horizontal,4).frame(height:16)
            .overlay(Rectangle().strokeBorder(FacetStyle.tagColor(tag),lineWidth:1))
    }
}

struct FacetGroup<Rows: View>: View {
    let title: String
    let key: String
    var active = false
    @ViewBuilder var rows: Rows
    @AppStorage private var open: Bool
    init(title: String, key: String, active: Bool = false, @ViewBuilder rows: () -> Rows) {
        self.title = title; self.key = key; self.active = active; self.rows = rows()
        _open = AppStorage(wrappedValue:false,"facetOpen." + key)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:1) {
            Button { withAnimation(.easeInOut(duration:0.15)) { open.toggle() } } label: {
                HStack(spacing:6) {
                    Text(title).font(.system(size:11,weight:.semibold)).tracking(0.4)
                        .foregroundStyle(active ? Color.acPink : Color.secondary.opacity(0.7))
                    Spacer(minLength:8)
                    Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold)).rotationEffect(.degrees(open || active ? 0 : -90))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }.padding(.horizontal,8).frame(height:26).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open || active { rows }
        }
    }
}

struct FacetGroups: View {
    @EnvironmentObject var model: AppModel
    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) { if set.contains(value) { set.remove(value) } else { set.insert(value) } }
    private func kindTitle(_ kind: AppModel.FileKind) -> String {
        switch kind { case .page: return "页面"; case .component: return "组件"; case .pdf: return "PDF"; case .media: return "图片与视频" }
    }
    private func kindSymbol(_ kind: AppModel.FileKind) -> String {
        switch kind { case .page: return "doc.text"; case .component: return "rectangle.grid.2x2"; case .pdf: return "doc.richtext"; case .media: return "photo" }
    }
    private func ageTitle(_ age: AppModel.FileAge) -> String {
        switch age { case .today: return "今天"; case .week: return "7 天内"; case .month: return "30 天内" }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            FacetGroup(title:model.localized("类型"),key:"kind",active:!model.facetKinds.isEmpty) {
                ForEach(AppModel.FileKind.allCases,id:\.self) { kind in
                    FacetRow(selected:model.facetKinds.contains(kind),action:{ toggle(&model.facetKinds,kind) }) {
                        Image(systemName:kindSymbol(kind)).font(.system(size:11)).frame(width:14)
                        Text(model.localized(kindTitle(kind)))
                    }
                }
            }
            let tags = model.scopedTags
            if !tags.isEmpty {
                FacetGroup(title:model.localized("标签"),key:"tag",active:!model.facetTags.isEmpty) {
                    ForEach(tags.prefix(12),id:\.self) { tag in
                        FacetRow(selected:model.facetTags.contains(tag),action:{ toggle(&model.facetTags,tag) }) { TagChip(tag:tag) }
                    }
                }
            }
            FacetGroup(title:model.localized("修改时间"),key:"age",active:model.facetAge != nil) {
                ForEach(AppModel.FileAge.allCases,id:\.self) { age in
                    FacetRow(selected:model.facetAge == age,action:{ model.facetAge = model.facetAge == age ? nil : age }) { Text(model.localized(ageTitle(age))) }
                }
            }
        }
    }
}

struct SidebarFilterField: View {
    @EnvironmentObject var model: AppModel
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing:7) {
            Image(systemName:"line.3.horizontal.decrease").font(.system(size:11,weight:.medium))
            TextField(model.localized("筛选"),text:$model.query).textFieldStyle(.plain).font(.system(size:12)).focused(focused)
                .onExitCommand { model.query = ""; focused.wrappedValue = false }
            if !model.query.isEmpty || model.facetsActive {
                Button { model.query = ""; model.clearFacets() } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).help(model.localized("清除筛选"))
            }
        }
        .foregroundStyle(.secondary).padding(.horizontal,8).frame(height:28)
        .background(Color.canvas,in:RoundedRectangle(cornerRadius:3))
        .overlay(RoundedRectangle(cornerRadius:3).strokeBorder(Color.faint))
    }
}
