import Foundation
import AppKit

@main
struct ModuleTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("acdian-module-tests-\(UUID().uuidString)",isDirectory:true)
        var suites: [String] = []
        defer {
            try? fm.removeItem(at:base)
            for suite in suites { UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
        }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"ModuleTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func pause(_ interval: TimeInterval) async { try? await Task.sleep(nanoseconds:UInt64(interval * 1_000_000_000)) }
        func eventually(_ message: String, _ condition: () -> Bool) async throws {
            for _ in 0..<300 { if condition() { checks += 1; return }; await pause(0.01) }
            throw NSError(domain:"ModuleTest",code:2,userInfo:[NSLocalizedDescriptionKey:message])
        }
        func vault(_ name: String, _ files: [String:String]) throws -> URL {
            let root = base.appendingPathComponent(name,isDirectory:true)
            for (path,content) in files {
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                if path.hasSuffix("/") { try fm.createDirectory(at:url,withIntermediateDirectories:true) } else { try Data(content.utf8).write(to:url) }
            }
            return root.standardizedFileURL.resolvingSymlinksInPath()
        }
        func model(_ root: URL, suite: String? = nil, delay: TimeInterval = 0) async throws -> AppModel {
            let name = suite ?? "acdian-module-tests-\(UUID().uuidString)"
            if suite == nil { suites.append(name) }
            let model = AppModel(preferences:UserDefaults(suiteName:name)!,pagesRoot:root,autosaveDelay:5,attachmentCleanupDelay:delay)
            try await eventually("The pages folder loads") { model.index != nil && !model.loading }
            return model
        }
        func open(_ model: AppModel, _ path: String) async throws {
            guard let file = model.index?.files.first(where: { $0.relativePath == path }) else { throw NSError(domain:"ModuleTest",code:3,userInfo:[NSLocalizedDescriptionKey:"Missing \(path)"]) }
            model.open(file,skipConfirmation:true,fromDisk:true)
            try await eventually("\(path) opens") { model.currentPagePath == path && !model.loading }
        }
        func cleanup(_ model: AppModel) async {
            var done = false
            model.runAttachmentCleanup { done = true }
            for _ in 0..<300 where !done { await pause(0.01) }
            // A timer may have started the same cleanup a moment earlier.
            await pause(0.4)
        }
        let png = String(decoding:Data([0x89,0x50,0x4E,0x47]),as:UTF8.self)

        // Discovery: each top-level folder is a module, in sidebar order, with a fitting kind and icon.
        let root = try vault("Vault",[
            "AGENTS.md":"# Agents\n",
            "Attachments/pic.png":png, "Attachments/shared.png":png, "Attachments/clip.mp4":"video", "Attachments/Old/kept.png":png,
            "Languages/Greek.md":"# Greek\n\nalpha", "Languages/English/GRE/abate.md":"# abate\n\nalpha",
            "Teaching/Lesson.md":"# Lesson\n\n![[pic.png|300]]\n\nalpha", "Teaching/Other.md":"# Other\n\n![[shared.png]]\n",
            "wandering-wondering/Essay.md":"# Essay\n\n![shared](../Attachments/shared.png \"title\")\n",
            ".acdian-order.json":#"{"":["wandering-wondering","Languages","Teaching","Attachments","AGENTS.md"]}"#,
        ])
        let discovered = ModuleStore.discover(root:root)
        try check(discovered.map(\.folder) == ["wandering-wondering","Languages","Teaching","Attachments"],"Top-level folders become modules in sidebar order")
        try check(discovered.first { $0.folder == "Attachments" }?.kind == .attachments && discovered.filter { $0.kind == .attachments }.count == 1,"Only the Attachments folder manages attachments")
        try check(discovered.first { $0.folder == "Teaching" }?.icon == "graduationcap" && discovered.first { $0.folder == "Languages" }?.icon == "character.bubble","Known folders get fitting icons")
        try check(!fm.fileExists(atPath:root.appendingPathComponent(ModuleStore.fileName).path),"Reading modules never writes a file by itself")
        try check(AttachmentReferences.targets(in:"![[a.png|300]] [[Page#Part]] ![x](<b c.png>) [y](d.png \"t\")") == ["a.png|300","Page#Part","b c.png","d.png"],"Wiki and Markdown link targets are read as written")

        let suite = "acdian-module-tests-\(UUID().uuidString)"; suites.append(suite)
        var app = try await model(root,suite:suite)
        try check(app.presentModules.count == 4 && app.activeModule == nil && app.sidebarEntries.count == 5,"Without a module open the sidebar shows every page")

        // A module scopes the sidebar and search to its folder.
        app.enterModule("Languages")
        try check(app.sidebarEntries.map(\.name) == ["English","Greek.md"],"An open module lists only its own folder")
        app.query = "alpha"
        try check(app.matches.map(\.relativePath).sorted() == ["Languages/English/GRE/abate.md","Languages/Greek.md"] || app.matches.map(\.relativePath).allSatisfy { $0.hasPrefix("Languages/") },"Search stays inside the open module")
        app.enterModule(nil)
        try check(app.query.isEmpty,"Changing module clears the search")

        // Hiding a module removes it from the sidebar and is remembered.
        app.setModuleHidden("Attachments",true)
        try check(!app.sidebarEntries.contains { $0.name == "Attachments" } && fm.fileExists(atPath:root.appendingPathComponent(ModuleStore.fileName).path),"A hidden module leaves the sidebar and the choice is saved")
        app.query = "clip"
        try check(app.matches.isEmpty,"Search skips hidden modules")
        app.query = ""

        // New pages started inside a module are saved in its folder.
        app.enterModule("Teaching")
        app.newPageFromEditor()
        try await eventually("A draft starts") { app.isDraft }
        app.draftTitle = "Plan"; app.text = "Body"
        try check(app.save() && fm.fileExists(atPath:root.appendingPathComponent("Teaching/Plan.md").path),"A page started in a module is saved in its folder")
        try check(app.index?.files.contains { $0.relativePath == "Teaching/Plan.md" } == true && app.sidebarEntries.contains { $0.relativePath == "Teaching/Plan.md" },"The new page shows in the module's sidebar at once")

        // Creating a module makes its folder, opens it, and is remembered with the open module.
        try check(app.createModule(name:"Projects",icon:"briefcase",color:"teal") && app.activeModuleID == "Projects","Creating a module opens it")
        var isFolder: ObjCBool = false
        try check(fm.fileExists(atPath:root.appendingPathComponent("Projects").path,isDirectory:&isFolder) && isFolder.boolValue,"A new module makes its folder")
        try check(!app.createModule(name:"projects",icon:"star",color:"pink") && app.error != nil,"A second module with the same folder is refused")
        app.error = nil
        let reopened = try await model(root,suite:suite)
        try check(reopened.modules.map(\.folder) == ["wandering-wondering","Languages","Teaching","Attachments","Projects"] && reopened.modules.first { $0.folder == "Attachments" }?.hidden == true,"Modules and their settings survive a relaunch")
        try check(reopened.currentPagePath == "Teaching/Plan.md" && reopened.activeModuleID == "Teaching","After a relaunch the sidebar shows the module of the restored front page")
        app.updateModule("Projects",name:"Work",icon:"hammer",color:"amber")
        try check(app.modules.last?.name == "Work" && app.modules.last?.folder == "Projects","Editing a module changes its name but not its folder")
        app.removeModule("Projects")
        try check(app.activeModuleID == nil && fm.fileExists(atPath:root.appendingPathComponent("Projects").path),"Removing a module keeps its folder")

        // Opening a page from another module while one is open follows it.
        app.enterModule("Languages")
        try await open(app,"Teaching/Lesson.md")
        try check(app.activeModuleID == "Teaching","Opening a page from another module switches the sidebar to it")
        app.enterModule(nil)
        try await open(app,"wandering-wondering/Essay.md")
        try check(app.activeModuleID == nil,"Without a module open, opening a page keeps the full sidebar")

        // Removing an image from a page sends it to the trash once no page links to it.
        try await open(app,"Teaching/Lesson.md")
        app.text = "# Lesson\n\nalpha"
        try check(app.save(),"The page without its image saves")
        await cleanup(app)
        try check(!fm.fileExists(atPath:root.appendingPathComponent("Attachments/pic.png").path) && app.trashEntries.contains { $0.originalRelativePath == "Attachments/pic.png" },"An image no page links to goes to the trash")
        try check(app.index?.files.contains { $0.relativePath == "Attachments/pic.png" } == false,"The trashed image leaves the index")

        // Typing the link again brings it back from the trash.
        app.text = "# Lesson\n\n![[pic.png|300]]\n\nalpha"
        try check(app.save(),"The page with the image again saves")
        try check(fm.fileExists(atPath:root.appendingPathComponent("Attachments/pic.png").path) && !app.trashEntries.contains { $0.originalRelativePath == "Attachments/pic.png" },"Linking a trashed image again restores it")
        try check(app.index?.resolve("pic.png",from:"Teaching/Lesson.md") != nil,"The restored image resolves at once")

        // An image another page still links to stays.
        try await open(app,"Teaching/Other.md")
        app.text = "# Other\n"
        try check(app.save(),"Removing a shared image saves")
        await cleanup(app)
        try check(fm.fileExists(atPath:root.appendingPathComponent("Attachments/shared.png").path),"An image still linked from another page (Markdown link, relative path) stays")

        // Changing only the label of an embed is not a removal.
        try await open(app,"Teaching/Lesson.md")
        app.text = "# Lesson\n\n![[pic.png|500]]\n\nalpha"
        try check(app.save(),"Resizing an image saves")
        await cleanup(app)
        try check(fm.fileExists(atPath:root.appendingPathComponent("Attachments/pic.png").path),"Changing an embed's size keeps the image")

        // A removed image pasted back before the delay ends is never trashed.
        let slow = try await model(root,suite:suite,delay:60)
        try await open(slow,"Teaching/Lesson.md")
        slow.text = "# Lesson\n\nalpha"
        try check(slow.save(),"Cutting an image saves")
        slow.text = "# Lesson\n\nalpha\n\n![[pic.png]]"
        try check(slow.save(),"Pasting it back saves")
        await cleanup(slow)
        try check(fm.fileExists(atPath:root.appendingPathComponent("Attachments/pic.png").path),"An image linked again within the delay stays")

        // Unsaved editor text counts as a link too.
        try await open(app,"Teaching/Lesson.md")
        app.text = "# Lesson\n\nalpha"
        try check(app.save(),"Removing the image saves")
        app.text = "# Lesson\n\nalpha ![[pic.png]]"
        await cleanup(app)
        try check(fm.fileExists(atPath:root.appendingPathComponent("Attachments/pic.png").path),"An image linked in unsaved editor text stays")

        // Renaming a module's folder in the sidebar keeps the module.
        app.enterModule("Languages")
        app.renamingPath = "Languages"
        app.finishRenaming("Languages",to:"Lenguas")
        try await eventually("The folder is renamed") { app.modules.contains { $0.folder == "Lenguas" } }
        try check(app.activeModuleID == "Lenguas" && app.modules.first { $0.folder == "Lenguas" }?.name == "Lenguas","Renaming a module's folder carries the module and its open state")

        app = try await model(root,suite:suite)
        try check(app.modules.contains { $0.folder == "Lenguas" },"The renamed module folder is saved")

        // Components: a Card Index placed in a module shows a folder, which leaves the sidebar.
        try check(ComponentStore.cardNote("UK /x/\n\n## Definitions\n\n- *verb* to become less strong\n") == "to become less strong","A card note is the first definition, without its part of speech")
        try check(ComponentStore.cardNote("Just a line of text.\n\nMore.") == "Just a line of text.","A page without definitions uses its first line")
        app.enterModule("Lenguas")
        try check(app.createComponent(.cardIndex,name:"Words",in:"Lenguas",source:"Lenguas/English/GRE",hideSource:true),"A component can be added to a module")
        try check(fm.fileExists(atPath:root.appendingPathComponent("Lenguas/Words.acdian").path) && app.currentPagePath == "Lenguas/Words.acdian","The component is saved as a small file and opens")
        try check(ComponentStore.read(root.appendingPathComponent("Lenguas/Words.acdian")) == ComponentInstance(component:.cardIndex,source:"Lenguas/English/GRE",hideSource:true),"The component file records its kind and folder")
        try check(app.componentInstances.count == 1 && app.componentHiddenFolders == ["Lenguas/English/GRE"],"The app lists the component and the folder it hides")
        try check(!app.createComponent(.recentPages,name:"a/b",in:"",source:"Teaching",hideSource:false),"Names with / are refused")
        app.error = nil
        try check(app.createComponent(.recentPages,name:"Words",in:"Lenguas",source:"Teaching",hideSource:false) && fm.fileExists(atPath:root.appendingPathComponent("Lenguas/Words 2.acdian").path),"A taken name gets a number")
        app.renamingPath = "Lenguas/English"
        app.finishRenaming("Lenguas/English",to:"Inglés")
        try await eventually("The component follows its renamed folder") { ComponentStore.read(root.appendingPathComponent("Lenguas/Words.acdian"))?.source == "Lenguas/Inglés/GRE" }
        app.showMarket()
        try await eventually("The component market opens") { app.showingMarket && !app.showingTrash && app.selected == nil }
        app.showTrash()
        try await eventually("The trash replaces the market") { app.showingTrash && !app.showingMarket }
        print("Modules: \(checks) checks passed")
    }
}
