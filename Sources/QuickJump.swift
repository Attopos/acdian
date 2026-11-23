import SwiftUI

struct QuickJumpView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var text: String
    @State private var everywhere = true
    @State private var selection = 0
    @FocusState private var focused: Bool
    init(text: String = "") { _text = State(initialValue:text) }
    var body: some View {
        let results = model.jumpResults(text,everywhere:everywhere || model.activeModule == nil)
        let all = results.titles + results.body
        ZStack(alignment:.top) {
            Color.black.opacity(scheme == .dark ? 0.45 : 0.16).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing:0) {
                field
                Rectangle().fill(Color.faint).frame(height:1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment:.leading,spacing:0) {
                            ForEach(Array(results.titles.enumerated()),id:\.element.id) { i,entry in
                                JumpRow(entry:entry,query:text,chain:true,selected:i == selection).id(i).onTapGesture { open(entry,split:false) }
                            }
                            if !results.body.isEmpty {
                                Text(model.localized("正文提到")).font(.system(size:11,weight:.semibold)).foregroundStyle(Color.secondary.opacity(0.7))
                                    .padding(.horizontal,18).padding(.top,12).padding(.bottom,4)
                                ForEach(Array(results.body.enumerated()),id:\.element.id) { i,entry in
                                    let n = results.titles.count + i
                                    JumpRow(entry:entry,query:"",chain:false,selected:n == selection).id(n).onTapGesture { open(entry,split:false) }
                                }
                            }
                            if all.isEmpty { Text(model.localized("没有找到匹配的文件")).font(.system(size:12)).foregroundStyle(.tertiary).padding(18) }
                        }.padding(.vertical,6)
                    }
                    .frame(maxHeight:520).fixedSize(horizontal:false,vertical:true)
                    .onChange(of:selection) { _,value in proxy.scrollTo(value) }
                }
            }
            .frame(width:680)
            .background(Color.rail,in:RoundedRectangle(cornerRadius:16,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).strokeBorder(Color.acPink,lineWidth:1))
            .padding(.top,84)
        }
        .onAppear { focused = true }
        .onChange(of:text) { _,_ in selection = 0 }
        .onChange(of:everywhere) { _,_ in selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1,max(all.count - 1,0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1,0); return .handled }
        .onKeyPress(.tab) { if model.activeModule != nil { everywhere.toggle() }; return .handled }
        .onKeyPress(.return) {
            guard all.indices.contains(selection) else { return .handled }
            open(all[selection],split:NSEvent.modifierFlags.contains(.option))
            return .handled
        }
        .onExitCommand { close() }
    }
    private var field: some View {
        HStack(spacing:10) {
            Image(systemName:"magnifyingglass").font(.system(size:16)).foregroundStyle(.secondary)
            TextField(model.localized("跳转到页面"),text:$text).textFieldStyle(.plain).font(.system(size:18)).focused($focused)
                .onExitCommand { close() }
            if let module = model.activeModule {
                HStack(spacing:6) {
                    ScopeChip(title:model.localized("全部模块"),on:everywhere) { everywhere = true }
                    ScopeChip(title:module.name,on:!everywhere) { everywhere = false }
                }
            }
        }.padding(.horizontal,18).frame(height:58)
    }
    private func open(_ entry: VaultEntry, split: Bool) {
        close()
        if split { model.openInSplit(entry) } else { model.open(entry) }
    }
    private func close() { model.showingJump = false }
}

private struct ScopeChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action:action) {
            Text(title).font(.system(size:11.5,weight:on ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(on ? Color(white:0.09) : Color.secondary)
                .padding(.horizontal,9).frame(height:24)
                .background(on ? Color.acPink : Color.wash,in:Capsule())
        }.buttonStyle(.plain)
    }
}

private struct JumpRow: View {
    @EnvironmentObject var model: AppModel
    let entry: VaultEntry
    let query: String
    let chain: Bool
    let selected: Bool
    var body: some View {
        let name = AppModel.editableName(entry)
        let facts = model.linkFacts[entry.relativePath]
        HStack(alignment:.top,spacing:12) {
            Image(systemName:FileRow.symbol(ext:entry.ext)).font(.system(size:14)).foregroundStyle(Color.acPink).frame(width:16).padding(.top,2)
            VStack(alignment:.leading,spacing:7) {
                HStack(spacing:5) {
                    ForEach(AppModel.titleTags(name).tags,id:\.self) { tag in TaggedTitle(name:"【\(tag)】",size:14) }
                    highlighted(AppModel.titleTags(name).tags.isEmpty ? name : AppModel.titleTags(name).title).font(.system(size:14,weight:chain ? .semibold : .regular)).lineLimit(1)
                }
                if chain, facts?.from != nil || facts?.to != nil {
                    HStack(spacing:6) {
                        if let from = facts?.from { pill(from,main:false); arrow }
                        pill(name,main:true)
                        if let to = facts?.to { arrow; pill(to,main:false) }
                    }
                }
            }
            Spacer(minLength:0)
        }
        .padding(.horizontal,18).padding(.vertical,chain ? 10 : 7)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(selected ? Color.acPink.opacity(0.14) : .clear)
        .contentShape(Rectangle())
    }
    private var arrow: some View { Image(systemName:"arrow.right").font(.system(size:10,weight:.semibold)).foregroundStyle(.tertiary) }
    private func pill(_ name: String, main: Bool) -> some View {
        let stripped = AppModel.titleTags(name).title, title = stripped.isEmpty ? name : stripped
        return Text(title.count > 22 ? title.prefix(21) + "…" : title).font(.system(size:11.5,weight:main ? .semibold : .regular)).lineLimit(1).fixedSize()
            .foregroundStyle(main ? Color(white:0.09) : Color.secondary)
            .padding(.horizontal,8).frame(height:22)
            .background(main ? Color.acPink : Color.wash,in:RoundedRectangle(cornerRadius:6,style:.continuous))
    }
    private func highlighted(_ name: String) -> Text {
        var value = AttributedString(name)
        let needle = query.trimmingCharacters(in:.whitespacesAndNewlines)
        if !needle.isEmpty, let range = value.range(of:needle,options:[.caseInsensitive,.diacriticInsensitive]) {
            value[range].backgroundColor = Color.acPink.opacity(0.28)
        }
        return Text(value)
    }
}
