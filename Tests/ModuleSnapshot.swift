import SwiftUI
import AppKit

// Renders the launcher, a module and the Attachments gallery for a pages
// folder into PNG files. Usage: module-snapshot <pages folder> <output folder>
@main
struct ModuleSnapshot {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath:args[1]), out = URL(fileURLWithPath:args[2])
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let suite = "acdian-module-snapshot-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName:suite) }
        let model = AppModel(preferences:UserDefaults(suiteName:suite)!,pagesRoot:root)
        model.language = args.count > 3 ? AppLanguage(rawValue:args[3]) ?? .english : .english
        for _ in 0..<500 where model.index == nil || model.loading { try await Task.sleep(nanoseconds:10_000_000) }
        let window = NSWindow(contentRect:NSRect(x:-8000,y:-8000,width:1260,height:840),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:ContentView().environmentObject(model))
        window.orderFrontRegardless()
        func shot(_ name: String, dark: Bool = false) async throws {
            window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            try await Task.sleep(nanoseconds:1_500_000_000)
            guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:image)
            try image.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(name + ".png"))
        }
        try await shot("1-launcher")
        try await shot("2-launcher-dark",dark:true)
        model.enterModule("Languages")
        model.setFolderExpanded("Languages/🇺🇸 English/GRE",true)
        model.setFolderExpanded("Languages/🇺🇸 English/GRE/A",true)
        try await shot("3-languages")
        model.enterModule("Attachments")
        try await Task.sleep(nanoseconds:3_000_000_000)
        try await shot("4-attachments")
        try await shot("5-attachments-dark",dark:true)
        model.enterModule("Teaching")
        try await shot("6-teaching")
        // Components: the card index page, a letter picked on its rail, and the market.
        if let page = model.index?.files.first(where: { $0.ext == ComponentStore.fileExtension }) {
            model.open(page,skipConfirmation:true)
            for _ in 0..<500 where model.searchedPageCount < 9000 { try await Task.sleep(nanoseconds:10_000_000) }
            try await shot("7-card-index",dark:true)
        }
        model.showMarket()
        try await shot("8-market")
        print("snapshots written")
        exit(0)
    }
}
