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
    var body: some View {
        HStack(spacing:0) {
            if model.showSidebar {
                SidebarView().frame(width:model.sidebarWidth)
                    .overlay(alignment:.trailing) { SidebarResizer().offset(x:4) }
                Rectangle().fill(Color.faint).frame(width:1)
            }
            VStack(spacing:0) {
                // No top bar: open pages sit as tabs in a transparent strip that
                // keeps clear of the window controls and still drags the window.
                // A hidden sidebar comes back with Control-Command-S or View > Show or hide sidebar.
                if model.selected != nil, !model.showingTrash, !model.showingMarket { pageColumns }
                else {
                    TabStrip().frame(height:TabStrip.height)
                    if model.showingTrash { TrashView(model:model) }
                    else if model.showingMarket { ComponentMarketView() }
                    else { HomeArea() }
                }
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
    // The open page and the split page side by side, as two equal columns
    // that each start with their own row of tabs. The divider drags, and a
    // double click on it evens the two out again.
    // Without a split page the open page's column takes the whole width.
    private var pageColumns: some View {
        GeometryReader { geometry in
            let available = geometry.size.width
            let split = model.splitEntry
            // Each column keeps a usable width; a window too small for that shares evenly.
            let least = min(320,available / 2)
            let leftWidth = split == nil ? available : min(max(available * model.splitFraction,least),available - least)
            // The columns keep their identity when the split opens, closes or
            // swaps sides, so neither editor is rebuilt.
            let order = split == nil ? ["main"] : model.splitOnLeft ? ["split","main"] : ["main","split"]
            HStack(spacing:0) {
                ForEach(order,id:\.self) { side in
                    let left = side == order[0]
                    pageColumn(split,main:side == "main",atWindowEdge:left).frame(width:left ? leftWidth : max(0,available - leftWidth))
                }
            }
            .overlay(alignment:.topLeading) { if split != nil { SplitDivider(width:available,leftWidth:leftWidth).offset(x:leftWidth - 5) } }
        }
    }
    @ViewBuilder private func pageColumn(_ split: VaultEntry?, main: Bool, atWindowEdge: Bool) -> some View {
        VStack(spacing:0) {
            if main { TabStrip(atWindowEdge:atWindowEdge).frame(height:TabStrip.height); documentBody }
            else if let split { SplitTabBar(entry:split,atWindowEdge:atWindowEdge).frame(height:TabStrip.height); SplitPane(entry:split) }
        }
        .frame(maxHeight:.infinity)
        .background(PaneClickWatcher { if model.splitFocused == main { model.splitFocused = !main } })
    }
    @ViewBuilder private var documentBody: some View {
        if let file = model.selected {
            VStack(spacing:0) {
                if file.ext == "md" {
                    // The text column stays centred in the window when the outline fits
                    // in the margin left of it with a clear gap. When it does not, the
                    // outline stays and the text moves right just far enough to clear
                    // it. Only a page too narrow for both gets the rail of short lines
                    // that opens over the margin while the pointer is on it.
                    GeometryReader { geometry in
                        let layout = Self.outlineLayout(geometry.size.width,shift:centerShift,showOutline:model.showOutline,push:model.splitEntry == nil)
                        let width = geometry.size.width - layout.reserve
                        let title = model.isDraft ? model.draftTitle : file.url.deletingPathExtension().lastPathComponent
                        ZStack(alignment:.topLeading) {
                            VStack(spacing:0) {
                                if model.isDraft { DraftTitleView(model:model,side:Self.pageSide(width),left:Self.pageLeft(width,shift:layout.shift)).id(model.editorDocumentID) }
                                LiveMarkdownEditor(model:model,centerShift:layout.shift).frame(maxWidth:.infinity,maxHeight:.infinity)
                            }.padding(.leading,layout.reserve)
                            if !model.showOutline {
                                Button { withAnimation(.easeInOut(duration:0.18)) { model.showOutline = true } } label: { Image(systemName:"chevron.right.2").font(.system(size:11,weight:.medium)).frame(width:22,height:22).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("文章目录")).padding(.leading,geometry.size.width > 700 ? 20 : 2).padding(.top,geometry.size.width > 700 ? 39 : 4)
                            } else if let docked = layout.outline {
                                outline(title:title,width:docked,floating:false)
                            } else {
                                OutlineRail(model:model,title:title,textLeft:Self.pageLeft(width,shift:layout.shift) + Self.pageSide(width),top:geometry.size.width > 700 ? 49 : 30,height:geometry.size.height) { outline(title:title,width:240,floating:true) }
                            }
                        }
                    }
                } else if file.ext == ComponentStore.fileExtension { ComponentPage(file:file).id(file.id) }
                else if file.ext == "pdf" { PDFPane(url:file.url,model:model).id(file.id) }
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
    // The editor column is at most 860 wide with empty padding inside each edge.
    // The outline docks in the margin left of the text only when that margin holds
    // a readable outline and a clear gap before the text (Aaron found 12 crowded);
    // it grows up to 240 with the margin. Narrower margins get the rail instead.
    static let outlineWidths: ClosedRange<CGFloat> = 200...240
    static let outlineGap: CGFloat = 48
    static func outlineDockWidth(_ width: CGFloat, shift: CGFloat) -> CGFloat? {
        let room = pageLeft(width,shift:shift) + pageSide(width) - outlineGap
        return room >= outlineWidths.lowerBound ? min(room,outlineWidths.upperBound) : nil
    }
    /// How the page makes room for the outline: `reserve` is the space the editor
    /// gives up on its left, `shift` the centre shift the editor then uses, and
    /// `outline` the docked outline's width, nil for the rail or no outline.
    struct OutlineLayout { var reserve: CGFloat = 0; var shift: CGFloat; var outline: CGFloat? }
    /// Narrowest editor left beside a pushed-in outline; below it the rail shows.
    static let pushedEditorMinimum: CGFloat = 480
    /// A split page keeps the two columns' text the same width, so it never pushes.
    static func outlineLayout(_ width: CGFloat, shift: CGFloat, showOutline: Bool, push: Bool = true) -> OutlineLayout {
        guard showOutline else { return OutlineLayout(shift:shift,outline:nil) }
        if let dock = outlineDockWidth(width,shift:shift) { return OutlineLayout(shift:shift,outline:dock) }
        guard push else { return OutlineLayout(shift:shift,outline:nil) }
        // The outline keeps its narrowest width and the text starts one gap past it:
        // the editor starts there less its own side padding, its column at its left edge.
        let outline = outlineWidths.lowerBound
        let reserve = max(0,outline + outlineGap - pageSide(width - outline))
        guard width - reserve >= pushedEditorMinimum else { return OutlineLayout(shift:shift,outline:nil) }
        return OutlineLayout(reserve:reserve,shift:width,outline:outline)
    }
    // The text column sits in the middle of the window, not of the space the
    // sidebar leaves: the editor moves it left by half the sidebar. A split page
    // shares the window, so each column keeps its text in its own middle.
    private var centerShift: CGFloat { model.showSidebar && model.splitEntry == nil ? CGFloat(model.sidebarWidth + 1) / 2 : 0 }
    // Where the 860-wide column starts in a page of this width, as --page-left in live-editor.css.
    static func pageLeft(_ width: CGFloat, shift: CGFloat) -> CGFloat { max(0,((width - 860) / 2 - shift).rounded(.down)) }
    // The empty space beside the text, by the page's width, as in live-editor.css.
    static func pageSide(_ width: CGFloat) -> CGFloat { width > 700 ? 58 : width > 450 ? 28 : 19 }
    private func outline(title: String, width: CGFloat, floating: Bool) -> some View {
        VStack(alignment:.leading,spacing:0) {
            Button { withAnimation(.easeInOut(duration:0.18)) { model.showOutline = false } } label: { Image(systemName:"chevron.left.2").font(.system(size:11,weight:.medium)) }.buttonStyle(.plain).foregroundStyle(.secondary).help(model.localized("文章目录")).padding(.bottom,16)
            ScrollView {
                VStack(alignment:.leading,spacing:4) {
                    Button { model.anchor = "#"; model.activeHeading = -1 } label: { Text(title.isEmpty ? "New Page" : title).font(.system(size:13,weight:.medium)).foregroundStyle(model.activeHeading < 0 ? Color.acPink : Color.primary.opacity(0.85)).lineLimit(2).multilineTextAlignment(.leading).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    ForEach(Array(model.headings.enumerated()),id:\.offset) { index,heading in
                        Button { model.anchor = heading.title; model.activeHeading = index } label: { Text(heading.title).font(.system(size:13)).foregroundStyle(index == model.activeHeading ? Color.acPink : heading.level <= 2 ? Color.primary.opacity(0.85) : Color.secondary).lineLimit(2).multilineTextAlignment(.leading).padding(.leading,CGFloat(max(0,heading.level-1))*12).padding(.vertical,5).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.scrollIndicators(.never) // .hidden still shows when the system always shows scroll bars.
        }.padding(.leading,floating ? 20 : 24).padding(.trailing,floating ? 14 : 8).padding(.top,floating ? 14 : 43).padding(.bottom,floating ? 14 : 0).frame(width:width,alignment:.topLeading)
        .background { if floating { RoundedRectangle(cornerRadius:10).fill(Color.rail).overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Color.faint,lineWidth:1)).shadow(color:.black.opacity(0.28),radius:16,y:6) } }
        .frame(maxHeight:floating ? nil : .infinity,alignment:.top)
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

// Tabs look and size like Chrome's: they sit on the bottom of a strip in the
// sidebar's colour, share its width evenly up to a comfortable maximum, and
// the front tab takes the page's colour so it runs on into the page below.
struct TabStrip: View {
    @EnvironmentObject var model: AppModel
    /// The strip starts at the window's left edge, under the window controls when the sidebar is hidden.
    var atWindowEdge = true
    @State private var hoveredID: UUID?
    static let height: CGFloat = 40
    var body: some View {
        GeometryReader { geometry in
            let leading: CGFloat = model.showSidebar || !atWindowEdge || model.fullScreen ? 8 : 76
            let count = CGFloat(model.tabs.count)
            // Neighbouring tabs overlap by their flares, so each tab gets back what it shares.
            let room = geometry.size.width - leading - 8 - ChromeTab.newTabWidth
            let width = model.tabs.isEmpty ? 0 : min(ChromeTab.maxWidth,max(ChromeTab.minWidth,(room + (count - 1) * ChromeTab.overlap) / count))
            let activeID: UUID? = model.selected != nil && !model.showingTrash && !model.showingMarket ? model.activeTabID : nil
            HStack(alignment:.bottom,spacing:0) {
                HStack(alignment:.bottom,spacing:-ChromeTab.overlap) {
                    ForEach(Array(model.tabs.enumerated()),id:\.element.id) { i, tab in
                        let previous: UUID? = i > 0 ? model.tabs[i-1].id : nil
                        // Like Chrome, a thin line parts two plain tabs and gives way next to the front or a hovered tab.
                        let separator = i > 0 && tab.id != activeID && tab.id != hoveredID && previous != activeID && previous != hoveredID
                        TabButton(tab:tab,active:tab.id == activeID,dimmed:model.splitEntry != nil && model.splitFocused,separator:separator,width:width,hovered:$hoveredID)
                            .zIndex(tab.id == activeID ? 2 : tab.id == hoveredID ? 1 : 0)
                    }
                }
                NewTabButton().padding(.leading,2).padding(.bottom,(ChromeTab.height - 28) / 2)
            }.padding(.leading,leading).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomLeading)
        }.background(Color.rail).contentShape(Rectangle()).clipped()
    }
}
struct TabButton: View {
    @EnvironmentObject var model: AppModel
    let tab: PageTab
    let active: Bool
    /// The front tab of the column that is not in use keeps its shape but greys its text.
    var dimmed = false
    var separator = false
    var width: CGFloat = ChromeTab.maxWidth
    @Binding var hovered: UUID?
    var body: some View {
        let hovering = hovered == tab.id
        ChromeTab(title:model.tabTitle(tab),symbol:FileRow.symbol(ext:((tab.path ?? "x.md") as NSString).pathExtension.lowercased()),active:active,dimmed:dimmed,hovering:hovering,separator:separator,width:width,closeLabel:model.localized("关闭标签页")) { model.closeTab(tab.id) }
            .onTapGesture { model.splitFocused = false; model.selectTab(tab.id) }
            .onHover { inside in if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil } }
            .help(tab.path ?? "")
    }
}
/// One Chrome-style tab: an icon, the title and a round close button, on a
/// shape with rounded top corners and outward flares at the bottom.
struct ChromeTab: View {
    static let height: CGFloat = 34
    static let flare: CGFloat = 8
    static let overlap: CGFloat = flare * 2
    static let maxWidth: CGFloat = 256
    static let minWidth: CGFloat = 64
    static let newTabWidth: CGFloat = 30
    let title: String
    let symbol: String
    let active: Bool
    var dimmed = false
    var hovering = false
    var separator = false
    var width: CGFloat = maxWidth
    let closeLabel: String
    let close: () -> Void
    @State private var closeHovering = false
    var body: some View {
        // Narrow tabs keep the close button for the front and the hovered tab only, like Chrome.
        let showClose = active || hovering || width >= 120
        HStack(spacing:8) {
            Image(systemName:symbol).font(.system(size:12)).frame(width:16,height:16)
                .foregroundStyle(active && !dimmed ? Color.acPink : Color.secondary.opacity(0.8))
            Text(title).font(.system(size:12.5)).lineLimit(1).truncationMode(.tail).frame(maxWidth:.infinity,alignment:.leading)
            if showClose {
                Button(action:close) { Image(systemName:"xmark").font(.system(size:9,weight:.bold)).frame(width:18,height:18).background(closeHovering ? Color.primary.opacity(0.12) : .clear,in:Circle()).contentShape(Circle()) }
                    .buttonStyle(.plain).onHover { closeHovering = $0 }.accessibilityLabel(closeLabel)
            }
        }
        .foregroundStyle(active && !dimmed ? Color.primary : Color.secondary)
        .padding(.leading,Self.flare + 10).padding(.trailing,Self.flare + 6)
        .frame(width:width,height:Self.height)
        .background {
            if active { ChromeTabShape(flare:Self.flare).fill(Color.canvas) }
            else if hovering { RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.06)).padding(.horizontal,Self.flare).padding(.vertical,4) }
        }
        .overlay(alignment:.leading) { if separator { Rectangle().fill(Color.primary.opacity(0.15)).frame(width:1,height:18).offset(x:Self.flare - 0.5) } }
        .contentShape(ChromeTabShape(flare:Self.flare))
    }
}
/// Rounded top corners, and bottom corners that curve outwards into the strip.
struct ChromeTabShape: Shape {
    var flare: CGFloat = 8
    var radius: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, f = flare, r = radius
        var p = Path()
        p.move(to:CGPoint(x:rect.minX,y:rect.minY + h))
        p.addQuadCurve(to:CGPoint(x:rect.minX + f,y:rect.minY + h - f),control:CGPoint(x:rect.minX + f,y:rect.minY + h))
        p.addLine(to:CGPoint(x:rect.minX + f,y:rect.minY + r))
        p.addQuadCurve(to:CGPoint(x:rect.minX + f + r,y:rect.minY),control:CGPoint(x:rect.minX + f,y:rect.minY))
        p.addLine(to:CGPoint(x:rect.minX + w - f - r,y:rect.minY))
        p.addQuadCurve(to:CGPoint(x:rect.minX + w - f,y:rect.minY + r),control:CGPoint(x:rect.minX + w - f,y:rect.minY))
        p.addLine(to:CGPoint(x:rect.minX + w - f,y:rect.minY + h - f))
        p.addQuadCurve(to:CGPoint(x:rect.minX + w,y:rect.minY + h),control:CGPoint(x:rect.minX + w - f,y:rect.minY + h))
        p.closeSubpath()
        return p
    }
}
/// The + after the last tab opens a new page in a new tab.
struct NewTabButton: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false
    var body: some View {
        Button { model.splitFocused = false; model.newPageFromEditor() } label: {
            Image(systemName:"plus").font(.system(size:13,weight:.medium)).frame(width:28,height:28)
                .background(hovering ? Color.primary.opacity(0.08) : .clear,in:Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).onHover { hovering = $0 }
        .help(model.localized("新建页面 ⌘N")).accessibilityLabel(model.localized("新建页面 ⌘N"))
    }
}

/// The sidebar's right edge. Dragging it sets the sidebar's width; a double
/// click puts the width back to where it started.
struct SidebarResizer: View {
    @EnvironmentObject var model: AppModel
    @State private var start: Double?
    var body: some View {
        Color.clear.frame(width:8).frame(maxHeight:.infinity).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global)
                .onChanged { drag in
                    let origin = start ?? model.sidebarWidth; start = origin
                    model.sidebarWidth = min(max((origin + drag.translation.width).rounded(),AppModel.sidebarWidths.lowerBound),AppModel.sidebarWidths.upperBound)
                }
                .onEnded { _ in start = nil; model.storeSidebarWidth() })
            .simultaneousGesture(TapGesture(count:2).onEnded { model.sidebarWidth = AppModel.defaultSidebarWidth; model.storeSidebarWidth() })
            .accessibilityLabel(model.localized("调整侧栏宽度"))
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
    var side: CGFloat = 58
    var left: CGFloat = 0
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
            .onChange(of:titleFocused) { _,focused in if !focused { model.draftTitleEnded() } }
            .padding(.horizontal,side).padding(.top,43).padding(.bottom,8)
            .frame(maxWidth:860,alignment:.leading)
            .padding(.leading,left)
            .frame(maxWidth:.infinity,alignment:.leading)
            .onAppear { titleFocused = true }
    }
}


struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    /// The search field shows only once ⌘F asks for it, or while a search is on.
    @State private var searching = false
    @State private var rootDropTargeted = false
    @State private var editingModule: ModuleEditorTarget?
    var body: some View {
        // With no module open and no search, the sidebar lists the modules instead of folders.
        let home = model.activeModule == nil && model.query.isEmpty
        VStack(spacing:0) {
            HStack(spacing:10) { BrandMark(size:30,style:model.iconStyle); Text("ACdian").font(.system(size:21,weight:.semibold,design:.rounded)).tracking(-0.6); Spacer(); SidebarToggle() }.padding(.horizontal,20).frame(height:68)
            ModuleBar()
            if searching || !model.query.isEmpty {
                HStack(spacing:8) { Image(systemName:"magnifyingglass").font(.system(size:12)); TextField(model.localized("搜索页面与内容"),text:$model.query).textFieldStyle(.plain).font(.system(size:12)).focused($searchFocused).onExitCommand { model.query = ""; searching = false }; Button { model.query = ""; searching = false } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain).help(model.localized("清除搜索")) }.foregroundStyle(.secondary).padding(10).background(Color.wash,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.faint)).padding(.horizontal,14).padding(.bottom,20)
            } else { Color.clear.frame(height:8) }
            if home {
                HStack { Text(model.localized("模块")).font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(Color.secondary.opacity(0.6)); Spacer(); Button { model.refresh() } label: { Image(systemName:"arrow.clockwise") }.help(model.localized("刷新页面")); Button { editingModule = .new } label: { Image(systemName:"plus") }.help(model.localized("新建模块")) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,10)
            } else {
            HStack { Text(model.query.isEmpty ? model.localized("页面") : model.localized("搜索结果")).font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(rootDropTargeted ? Color.acPink : Color.secondary.opacity(0.6)).onDrop(of:SidebarDrops.types,isTargeted:$rootDropTargeted) { providers in
                // Dropping on the Pages header puts an item at the top of the open module.
                let target = PageDropTarget(folder:model.activeModule?.folder ?? "")
                return SidebarDrops.perform(providers,target:target,model:model) { model.movePage($0,to:target) }
            }; Spacer(); Button { model.refresh() } label: { Image(systemName:"arrow.clockwise") }.help(model.localized("刷新页面")); Button { model.newFolder(in:model.activeModule?.folder ?? "") } label: { Image(systemName:"folder.badge.plus") }.help(model.localized("新建文件夹")); Button { model.newPageFromEditor() } label: { Image(systemName:"square.and.pencil") }.help(model.localized("新建页面 ⌘N")) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,10)
            }
            ScrollView {
                ThinScrollBar().frame(width:0,height:0)
                if home { SidebarModuleList { editingModule = $0 }.padding(.horizontal,10).padding(.bottom,20) }
                else if model.query.isEmpty { SidebarTree(entries:model.sidebarEntries).padding(.horizontal,10).padding(.bottom,20) }
                else {
                    let matches = model.matches
                    LazyVStack(spacing:2) { ForEach(matches.prefix(500)) { entry in FileRow(entry:entry,indent:0,showPath:true) }; if matches.isEmpty { Text(model.localized("没有找到匹配的文件")).font(.caption).foregroundStyle(.tertiary).padding(.top,25) } }
                        .padding(.horizontal,10).padding(.bottom,20)
                }
            }.scrollIndicators(.never)
            Spacer(minLength:0)
            Button { model.showMarket() } label: {
                HStack(spacing:10) { Image(systemName:"puzzlepiece.extension").frame(width:16); Text(model.localized("组件")); Spacer() }
                    .font(.system(size:12,weight:.medium)).foregroundStyle(model.showingMarket ? Color.acPink : Color.secondary)
                    .padding(.horizontal,12).padding(.vertical,9)
                    .background(model.showingMarket ? Color.acPink.opacity(0.09) : .clear,in:RoundedRectangle(cornerRadius:7))
            }.buttonStyle(.plain).padding(.horizontal,10).accessibilityIdentifier("componentsButton")
            Button { model.showTrash() } label: {
                HStack(spacing:10) { Image(systemName:"trash").frame(width:16); Text(model.localized("垃圾桶")); Spacer() }
                    .font(.system(size:12,weight:.medium)).foregroundStyle(model.showingTrash ? Color.acPink : Color.secondary)
                    .padding(.horizontal,12).padding(.vertical,9)
                    .background(model.showingTrash ? Color.acPink.opacity(0.09) : .clear,in:RoundedRectangle(cornerRadius:7))
            }.buttonStyle(.plain).padding(.horizontal,10).padding(.bottom,12)
                .accessibilityIdentifier("trashButton")
                .contextMenu { Button(role:.destructive) { model.confirmEmptyTrash() } label: { Label(model.localized("清空垃圾桶…"),systemImage:"trash.slash") }.disabled(model.trashEntries.isEmpty) }
            Rectangle().fill(Color.faint).frame(height:1).padding(.horizontal,16)
            HStack(spacing:14) { SettingsButton(); Spacer() }.padding(.horizontal,20).padding(.vertical,14)
        }.background(Color.rail)
        .sheet(item:$editingModule) { target in ModuleEditor(target:target).environmentObject(model) }
        .onChange(of:searchFocused) { _,focused in if !focused && model.query.isEmpty { searching = false } }
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("acdianSearch"))) { _ in
            model.showSidebar = true; searching = true
            // The field is new on this pass, so it takes focus on the next.
            DispatchQueue.main.async { searchFocused = true }
        }
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
        // A folder shown by a component is left out; the component stands for it.
        let hidden = model.componentHiddenFolders
        func add(_ entries: [VaultEntry], _ depth: Int) {
            for entry in entries where !hidden.contains(entry.relativePath) {
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
            .sidebarDropIndicator(entry.relativePath,drag:model.drag)
            .onDrag { model.draggingPath = entry.relativePath; return NSItemProvider(object:entry.relativePath as NSString) }
            .onDrop(of:SidebarDrops.types,delegate:SidebarDropDelegate(model:model,entry:entry,height:29) { model.setFolderExpanded(entry.relativePath,true) })
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
    var symbol: String { Self.symbol(ext:entry.ext) }
    static func symbol(ext: String) -> String { if ext == "md" { return "doc.text" }; if ext == "pdf" { return "doc.richtext" }; if AppModel.images.contains(ext) { return "photo" }; if AppModel.videos.contains(ext) { return "film" }; if ext == ComponentStore.fileExtension { return "rectangle.grid.2x2" }; return "doc" }
    private var isCurrentPage: Bool { model.currentPagePath == entry.relativePath || model.splitPath == entry.relativePath }
    var body: some View {
        if model.renamingPath == entry.relativePath {
            RenameRow(entry:entry,leading:CGFloat(indent)*13+23,symbol:symbol,tint:Color.acPink).id(model.renamingSession)
        } else { row }
    }
    private var row: some View {
        Button { model.openInFocusedColumn(entry) } label: {
            HStack(spacing:8) { Image(systemName:symbol).font(.system(size:12)).frame(width:14).foregroundStyle(isCurrentPage ? Color.acPink : Color.secondary.opacity(0.65)); VStack(alignment:.leading,spacing:3) { Text(AppModel.editableName(entry)).font(.system(size:12)).lineLimit(1); if showPath { Text(entry.relativePath).font(.system(size:9)).foregroundStyle(.tertiary).lineLimit(1) } }; Spacer(minLength:0) }.foregroundStyle(isCurrentPage ? Color.primary : Color.secondary).padding(.leading,CGFloat(indent)*13+23).padding(.trailing,10).padding(.vertical,7).contentShape(Rectangle()).background(isCurrentPage ? Color.acPink.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
        }.buttonStyle(.plain).help(entry.relativePath)
        .simultaneousGesture(TapGesture(count:2).onEnded { model.startRenaming(entry) })
        .contextMenu {
            Button { model.openInSplit(entry) } label: { Label(model.localized("在分屏中打开"),systemImage:"rectangle.split.2x1") }
                .disabled(entry.relativePath == model.currentPagePath || entry.relativePath == model.splitPath)
            Divider()
            Button { model.newFolder(near:entry) } label: { Label(model.localized("新建文件夹"),systemImage:"folder.badge.plus") }
            Button { model.startRenaming(entry) } label: { Label(model.localized("重命名"),systemImage:"pencil") }
            MoveToMenu(entry:entry)
            Divider()
            Button(role:.destructive) { model.delete(entry) } label: { Label(model.localized("删除"),systemImage:"trash") }
        }
        .sidebarDropIndicator(entry.relativePath,drag:model.drag)
        .onDrag { model.draggingPath = entry.relativePath; return NSItemProvider(object:entry.relativePath as NSString) }
        .onDrop(of:SidebarDrops.types,delegate:SidebarDropDelegate(model:model,entry:entry,height:nil))
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
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to:SidebarDrops.types) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.setSidebarDrop(SidebarDropHighlight(path:entry.relativePath,place:placement(info)))
        return DropProposal(operation:model.draggingPath == nil && info.hasItemsConforming(to:[.fileURL]) ? .copy : .move)
    }
    func dropExited(info: DropInfo) { if model.sidebarDrop?.path == entry.relativePath { model.setSidebarDrop(nil) } }
    func performDrop(info: DropInfo) -> Bool {
        let place = placement(info); model.setSidebarDrop(nil)
        let parent = entry.relativePath.split(separator:"/").dropLast().joined(separator:"/")
        let target = place == .into ? PageDropTarget(folder:entry.relativePath) : PageDropTarget(folder:parent,anchor:entry.name,after:place == .after)
        if place == .into, model.draggingPath == nil { onInto() }
        return SidebarDrops.perform(info.itemProviders(for:SidebarDrops.types),target:target,model:model) { path in
            guard path != entry.relativePath else { return }
            model.movePage(path,to:target); if place == .into { onInto() }
        }
    }
}
/// What the sidebar accepts: rows dragged within it, which move, and files
/// from Finder or other apps, which are copied in.
enum SidebarDrops {
    static let types: [UTType] = [.fileURL,.text]
    @MainActor static func perform(_ providers: [NSItemProvider], target: PageDropTarget, model: AppModel, move: @escaping (String) -> Void) -> Bool {
        // A drag that started in this sidebar is moved at once.
        if let path = model.draggingPath { move(path); return true }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            let group = DispatchGroup(), lock = NSLock()
            var urls: [URL] = []
            for provider in files {
                group.enter()
                _ = provider.loadObject(ofClass:URL.self) { url,_ in
                    if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue:.main) { model.importFiles(urls,to:target) }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass:NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass:NSString.self) { object,_ in
            if let path = object as? String { DispatchQueue.main.async { move(path) } }
        }
        return true
    }
}
extension View {
    func sidebarDropIndicator(_ path: String, drag: SidebarDragState) -> some View { modifier(SidebarDropIndicator(path:path,drag:drag)) }
}
/// The insertion line or folder highlight under a drag. Only this redraws as
/// the pointer moves, not the row or the sidebar around it.
struct SidebarDropIndicator: ViewModifier {
    let path: String
    @ObservedObject var drag: SidebarDragState
    func body(content: Content) -> some View {
        let drop = drag.highlight?.path == path ? drag.highlight?.place : nil
        content.overlay(alignment:drop == .after ? .bottom : .top) {
            if drop == .before || drop == .after { Rectangle().fill(Color.acPink).frame(height:2).padding(.horizontal,8) }
        }
        .background(drop == .into ? Color.acPink.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:6))
    }
}
struct TrashView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.firstTextBaseline) {
                Text(model.localized("垃圾桶")).font(.system(size:28,weight:.bold))
                Spacer()
                if !model.trashEntries.isEmpty {
                    Button(role:.destructive) { model.confirmEmptyTrash() } label: { Label(model.localized("清空垃圾桶…"),systemImage:"trash.slash") }
                        .buttonStyle(.bordered).accessibilityIdentifier("emptyTrash")
                }
            }
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
                            .contextMenu {
                                Button(model.localized("恢复")) { model.restoreFromTrash(entry) }
                                Divider()
                                Button(model.localized("清空垃圾桶…"),role:.destructive) { model.confirmEmptyTrash() }
                            }
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
    @State private var confirmingMove = false
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
            if model.canMoveToICloud || model.movingToICloud {
                section("iCloud") {
                    Text(model.localized("把所有页面复制到 iCloud 云盘，校验每个文件后改用 iCloud 里的这份。原文件夹保持不动，作为备份。")).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    if model.movingToICloud { HStack(spacing:6) { ProgressView().controlSize(.small); Text(model.localized("正在复制到 iCloud…")).font(.system(size:11)) } }
                    else { Button(model.localized("移到 iCloud")) { confirmingMove = true }.buttonStyle(.bordered) }
                }
            }
            if let backup = model.pagesBackupPath {
                section("iCloud") {
                    Text(model.localized("原文件夹保留在：")).font(.system(size:11)).foregroundStyle(.secondary)
                    Text(backup).font(.system(size:11)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                }
            }
        }.padding(18).frame(width:330,alignment:.leading).tint(.acPink)
        .alert(model.localized("移动页面到 iCloud？"),isPresented:$confirmingMove) {
            Button(model.localized("移动")) { model.movePagesToICloud() }
            Button(model.localized("取消"),role:.cancel) {}
        } message: { Text(model.localized("把所有页面复制到 iCloud 云盘，校验每个文件后改用 iCloud 里的这份。原文件夹保持不动，作为备份。")) }
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

// The outline when the margin is too narrow for it: one short line per heading,
// longer for higher levels and pink for the part being read. Pointing at it opens
// the whole outline over the margin and the text's edge; leaving closes it. The
// text never moves for it.
struct OutlineRail<Panel: View>: View {
    @ObservedObject var model: AppModel
    let title: String
    /// Where the text starts in the page, so the rail stays in the empty margin.
    let textLeft: CGFloat
    let top: CGFloat
    /// The page's height, which the open outline stays inside.
    let height: CGFloat
    @ViewBuilder let panel: () -> Panel
    @State private var open = false
    @State private var closing: Task<Void,Never>?
    var body: some View {
        let leading = max(4,min(22,textLeft - 26))
        ZStack(alignment:.topLeading) {
            if open {
                // About 30 points a heading, plus the close button and the panel's padding; longer outlines scroll.
                panel().frame(height:max(120,min(height - max(4,top - 14) - 12,CGFloat(model.headings.count + 1) * 31 + 62)),alignment:.top)
                    .padding(.leading,max(6,leading - 8)).padding(.top,max(4,top - 14))
                    .onHover(perform:hover)
                    .transition(.opacity)
            } else {
                VStack(alignment:.leading,spacing:7) {
                    line(level:1,active:model.activeHeading < 0)
                    ForEach(Array(model.headings.prefix(48).enumerated()),id:\.offset) { index,heading in line(level:heading.level + 1,active:index == model.activeHeading) }
                }
                .padding(.vertical,6).padding(.horizontal,6).contentShape(Rectangle())
                .onHover(perform:hover)
                .help(model.localized("文章目录"))
                .padding(.leading,leading - 6).padding(.top,top - 6)
                .accessibilityElement(children:.ignore).accessibilityLabel(model.localized("文章目录"))
            }
        }
    }
    private func line(level: Int, active: Bool) -> some View {
        Capsule().fill(active ? Color.acPink : Color.secondary.opacity(0.4)).frame(width:level <= 1 ? 16 : level == 2 ? 12 : level == 3 ? 9 : 6,height:2)
    }
    // Moving from the rail onto the panel that replaces it reads as leaving and
    // coming back, so a close waits a moment for the pointer to arrive.
    private func hover(_ inside: Bool) {
        closing?.cancel()
        if inside { if !open { withAnimation(.easeOut(duration:0.12)) { open = true } } }
        else { closing = Task { @MainActor in try? await Task.sleep(nanoseconds:220_000_000); guard !Task.isCancelled else { return }; withAnimation(.easeIn(duration:0.12)) { open = false } } }
    }
}

// A thin scroll bar for the scroll view it sits in, in place of the system one
// (whose overlay style still flashed a wide grey bar whenever the sidebar's
// contents changed). It shows only while the list scrolls or the pointer is over
// the list, fades a moment later, and its knob can be dragged.
// The ScrollView itself is given .scrollIndicators(.never).
struct ThinScrollBar: NSViewRepresentable {
    final class Probe: NSView {
        private weak var bar: Bar?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard bar == nil, let scroll = enclosingScrollView else { return }
            let bar = Bar(scroll:scroll); self.bar = bar
            scroll.addSubview(bar); bar.place()
        }
        override func removeFromSuperview() { bar?.removeFromSuperview(); super.removeFromSuperview() }
    }
    final class Bar: NSView {
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var hideWork: DispatchWorkItem?
        private var dragStart: (y: CGFloat, origin: CGFloat)?
        private var hovering = false
        static let width: CGFloat = 12
        init(scroll: NSScrollView) {
            self.scroll = scroll
            super.init(frame:.zero)
            wantsLayer = true; alphaValue = 0
            let clip = scroll.contentView; clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:clip,queue:.main) { [weak self] _ in self?.reveal() })
            scroll.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:scroll,queue:.main) { [weak self] _ in self?.place() })
            scroll.addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil))
        }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        override var isFlipped: Bool { true }
        override func mouseEntered(with event: NSEvent) { hovering = true; reveal() }
        override func mouseExited(with event: NSEvent) { hovering = false; scheduleHide() }
        override func layout() { super.layout(); place() }
        func place() {
            guard let scroll else { return }
            let box = scroll.bounds
            frame = NSRect(x:box.maxX - Self.width,y:box.minY,width:Self.width,height:box.height)
            autoresizingMask = [.minXMargin,.height]
            needsDisplay = true
        }
        /// The knob's rect in this view, nil when everything fits.
        private var knob: NSRect? {
            guard let scroll, let document = scroll.documentView else { return nil }
            let visible = scroll.contentView.bounds.height, total = document.frame.height
            guard total > visible + 1 else { return nil }
            let track = bounds.height - 8
            let height = max(28,track * visible / total)
            let progress = min(1,max(0,scroll.contentView.bounds.minY / (total - visible)))
            return NSRect(x:bounds.width - 7,y:4 + (track - height) * progress,width:4,height:height)
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let knob else { return }
            NSColor.secondaryLabelColor.withAlphaComponent(dragStart != nil ? 0.7 : 0.45).setFill()
            NSBezierPath(roundedRect:knob,xRadius:2,yRadius:2).fill()
        }
        func reveal() {
            if superview != nil, frame.width == 0 { place() }
            needsDisplay = true
            guard knob != nil else { alphaValue = 0; return }
            hideWork?.cancel()
            if alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 } }
            scheduleHide()
        }
        private func scheduleHide() {
            hideWork?.cancel()
            guard !hovering, dragStart == nil else { return }
            let work = DispatchWorkItem { [weak self] in NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self?.animator().alphaValue = 0 } }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.9,execute:work)
        }
        // Clicks land only on the knob (or the strip it runs in while showing); the rest goes to the list.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard alphaValue > 0.5, knob != nil, let local = superview.map({ convert(point,from:$0) }), bounds.contains(local) else { return nil }
            return self
        }
        override func mouseDown(with event: NSEvent) {
            guard let scroll, let knob else { return }
            let y = convert(event.locationInWindow,from:nil).y
            if !knob.contains(NSPoint(x:knob.midX,y:y)) { scrollTo(knobTop:y - knob.height / 2) }
            dragStart = (y,self.knob?.minY ?? knob.minY); hideWork?.cancel(); needsDisplay = true
            _ = scroll
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            scrollTo(knobTop:start.origin + convert(event.locationInWindow,from:nil).y - start.y)
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil; needsDisplay = true; scheduleHide() }
        private func scrollTo(knobTop: CGFloat) {
            guard let scroll, let document = scroll.documentView, let knob else { return }
            let track = bounds.height - 8, visible = scroll.contentView.bounds.height, total = document.frame.height
            let progress = min(1,max(0,(knobTop - 4) / max(1,track - knob.height)))
            scroll.contentView.scroll(to:NSPoint(x:scroll.contentView.bounds.minX,y:progress * (total - visible)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}
