import Foundation

@main
struct RoadmapTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !condition() { throw NSError(domain:"RoadmapTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
            checks += 1
        }
        func document(_ json: String) -> RoadmapDocument? { RoadmapDocument.decode(Data(json.utf8)) }

        let full = try check2(document("""
        {"component":"roadmap","source":"CS","version":1,"title":"CS 路线图","future":{"a":[1,2]},
         "domains":[{"id":"network","title":"网络","color":"sky","glyph":"network","order":0},{"id":"odd","title":"奇怪","color":"neon","order":1,"extra":true}],
         "nodes":[
          {"id":"http","title":"HTTP","domain":"network","level":0,"pages":[],"summary":"s","keyPoints":[],"status":"new","updated":10,"draft":true},
          {"id":"proxy","title":"反向代理","domain":"network","level":9,"pages":["CS/反向代理"],"summary":"s","keyPoints":[{"text":"t","page":"CS/反向代理","heading":"一句话"},{"bad":1}],"x":12.5,"y":40,"status":"mastered","updated":11,"later":"ignored"},
          {"title":"no id"}, 7,
          {"id":"bare"}],
         "edges":[{"id":"http>proxy","from":"http","to":"proxy","kind":"requires","why":"w","updated":5},{"from":"proxy","to":"bare","kind":"mystery"},{"to":"x"}],
         "removed":{"node:gone":100},"exclude":["【Prompt】cs-study"]}
        """),"A roadmap with unknown and broken items decodes")
        try check(full.title == "CS 路线图" && full.source == "CS" && full.exclude == ["【Prompt】cs-study"],"Top-level fields are read")
        try check(full.domains.map(\.color) == ["sky","graphite"],"A colour outside the module palette falls back to graphite")
        try check(full.nodes.map(\.id) == ["http","proxy","bare"],"Nodes without an id and non-objects are skipped, the rest are kept")
        try check(full.nodes[1].level == 3 && full.nodes[1].status == "new" && full.nodes[1].x == 12.5 && full.nodes[1].keyPoints.count == 1,"Out-of-range level and unknown status are normalised; a broken key point is skipped")
        try check(full.nodes[0].draft == true && full.nodes[2].title == "bare" && full.nodes[2].pages.isEmpty && full.nodes[2].updated == 0,"Missing fields take defaults")
        try check(full.edges.count == 2 && full.edges[1].kind == "related" && full.edges[1].id == "proxy~bare","An edge without an id gets one, an unknown kind becomes related, a broken edge is skipped")
        try check(document(#"{"component":"card-index","source":"CS"}"#) == nil && document(#"{"source":"CS"}"#) == nil,"Only roadmap components decode as a roadmap")
        try check(document(#"{"component":"roadmap"}"#) == RoadmapDocument(),"A bare roadmap is empty")
        let again = try check2(RoadmapDocument.decode(try full.encoded()),"An encoded roadmap decodes")
        try check(again == full,"Encoding and decoding round-trips")
        try check(ComponentStore.encodeProbe(full) == .roadmap,"The component reader recognises a roadmap file")

        let science = """
        *简单科普 · 2026-11*

        ## 一句话

        **反向代理**是站在**网站那一边**的代理：你以为自己在直接访问网站，其实接待你的是它，它再把请求转给后面真正干活的服务器。

        ```
        你 ──► 反向代理 ──► 服务器 1
        ```

        ![[proxy-shot.png]]
        ![[proxy-fig-1.svg]]

        ## 正向代理 vs 反向代理

        详见 [[链式代理]] 和 [封锁](../Articles/封锁.md)。![图](a/b.png)
        """
        try check(RoadmapSummary.extract(science) == "反向代理是站在网站那一边的代理：你以为自己在直接访问网站，其实接待你的是它，它再把请求转给后面真正干活的服务器。","A primer's summary is the paragraph under 一句话, without Markdown marks")
        try check(RoadmapSummary.figures(science) == ["proxy-fig-1.svg","proxy-shot.png","a/b.png"],"Figures list diagrams first and skip code blocks")
        try check(RoadmapSummary.links(science) == ["链式代理","../Articles/封锁.md"],"Links leave image embeds out")
        let prysm = """
        > 范围：Prysm 生产环境的公网入口。

        > 证据边界：集群里的声明来自只读盘点。

        ## 1. 一句话说明

        ALB 是 Prysm 的「大门 + 前台」：所有客户、SDK、控制台的请求都先到它，它负责 HTTPS 解密、按域名和路径分流，再把请求平均派给后面 60 个 API Pod；它自己不跑业务代码，也不知道请求里是哪个模型。

        ## 2. 结构图
        """
        let short = RoadmapSummary.extract(prysm)
        try check(short.hasPrefix("ALB 是 Prysm 的「大门 + 前台」：所有客户、SDK、控制台的请求都先到它") && short.count <= 80 && short.hasSuffix("…"),"A long Prysm summary is cut at a clause within 80 characters: \(short)")
        let article = "*Addy Osmani · November 3, 2026 · [Original](https://x.com/a)*\n\n![[cover.jpg]]\n\nBack in the day, **critical thinking** was taught.\n\nSecond paragraph."
        try check(RoadmapSummary.extract(article) == "Back in the day, critical thinking was taught.","Without a 一句话 heading the first prose paragraph is used, past the byline and cover")
        try check(RoadmapSummary.extract("") == "" && RoadmapSummary.extract("## 只有标题") == "","A page without prose has no summary")

        func node(_ id: String, _ updated: Double, status: String = "new") -> RoadmapNode {
            RoadmapNode(id:id,title:id,domain:"d",level:0,pages:[],summary:"",keyPoints:[],x:nil,y:nil,status:status,updated:updated,draft:nil,note:nil)
        }
        func edge(_ from: String, _ to: String, _ updated: Double, kind: String = "requires") -> RoadmapEdge {
            RoadmapEdge(id:from + (kind == "related" ? "~" : ">") + to,from:from,to:to,kind:kind,why:"",updated:updated)
        }
        let now: Double = 1_000_000
        var disk = RoadmapDocument(source:"CS",title:"T",nodes:[node("a",10),node("b",10),node("c",10)],edges:[edge("a","b",10),edge("b","c",10)])
        var local = disk
        local.nodes = [node("a",20,status:"learned"),node("b",5,status:"learning"),node("d",20)]; local.edges = [edge("a","d",20)]; local.removed = ["node:c":now - 10]
        var merged = MetadataMerge.roadmap(local:local,disk:disk,now:now)
        try check(merged.nodes.map(\.id) == ["a","b","d"],"Disk order is kept, new nodes are added and a deleted node goes")
        try check(merged.nodes[0].status == "learned" && merged.nodes[1].status == "new","The newer copy of each node wins")
        try check(merged.edges.map(\.id) == ["a>b","a>d"],"Edges of a deleted node go with it; new edges are added")
        try check(merged.removed["node:c"] == now - 10 && merged.title == "T" && merged.source == "CS","Deletions are remembered")
        disk.nodes[2].updated = now
        merged = MetadataMerge.roadmap(local:local,disk:disk,now:now)
        try check(merged.nodes.contains { $0.id == "c" },"A node edited after its deletion survives")
        local.removed = ["node:c":now - RoadmapDocument.tombstoneLife - 1,"edge:a>b":now - 5]
        disk.nodes[2].updated = 10
        merged = MetadataMerge.roadmap(local:local,disk:disk,now:now)
        try check(merged.removed.keys.sorted() == ["edge:a>b"] && merged.nodes.contains { $0.id == "c" } && !merged.edges.contains { $0.id == "a>b" },"Deletions older than 90 days are forgotten; edge deletions apply")
        try check(MetadataMerge.roadmap(local:disk,disk:nil,now:now) == disk,"With nothing on disk the local copy stands")
        var partial = disk; partial.nodes = [node("b",30,status:"learned")]; partial.edges = []; partial.removed = [:]
        merged = MetadataMerge.roadmap(local:partial,disk:disk,now:now)
        try check(merged.nodes.map(\.id) == ["a","b","c"] && merged.nodes[1].status == "learned" && merged.edges == disk.edges,"Saving one changed node leaves the rest of the file as it was")

        try check(RoadmapGraph.reaches("a","c",in:disk.edges) && !RoadmapGraph.reaches("c","a",in:disk.edges),"Reachability follows directed edges")
        try check(RoadmapGraph.isAcyclic(disk.edges) && RoadmapGraph.isAcyclic(disk.edges + [edge("c","a",50,kind:"related")]),"Related edges never make a loop")
        try check(RoadmapGraph.cycleEdges(disk.edges + [edge("c","a",50)]) == ["c>a"],"The newest edge that closes a loop is the one dropped")
        var looped = disk; looped.edges.append(edge("c","a",50,kind:"applies"))
        merged = MetadataMerge.roadmap(local:looped,disk:disk,now:now)
        try check(merged.edges.map(\.id) == ["a>b","b>c"] && merged.removed["edge:c>a"] == now,"A merge never leaves a loop")

        var moving = RoadmapDocument(source:"CS",nodes:[RoadmapNode(id:"n",title:"n",domain:"d",level:0,pages:["CS/旧","Articles/x"],summary:"",keyPoints:[RoadmapPoint(text:"t",page:"CS/旧",heading:"h")],x:nil,y:nil,status:"new",updated:1,draft:nil,note:nil)],exclude:["CS/旧"])
        moving.movePages(from:"CS/旧",to:"CS/新",at:9)
        try check(moving.nodes[0].pages == ["CS/新","Articles/x"] && moving.nodes[0].keyPoints[0].page == "CS/新" && moving.nodes[0].updated == 9 && moving.exclude == ["CS/新"],"A renamed page is followed")
        moving.movePages(from:"CS",to:"Notes",at:12)
        try check(moving.nodes[0].pages == ["Notes/新","Articles/x"],"A renamed folder is followed")

        let modules = try JSONDecoder().decode([PageModule].self,from:Data(#"[{"folder":"CS","name":"CS","icon":"terminal","color":"sky","kind":"pages","hidden":false,"home":"CS/CS 路线图.acdian"},{"folder":"Notes"}]"#.utf8))
        try check(modules[0].home == "CS/CS 路线图.acdian" && modules[1].home == nil,"A module's home is optional")
        let saved = String(decoding:try JSONEncoder().encode(modules),as:UTF8.self)
        try check(saved.contains("路线图.acdian") && saved.components(separatedBy:"\"home\"").count == 2,"The home is written only where it is set")

        print("Roadmap tests passed: \(checks) checks")
    }
    static func check2<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain:"RoadmapTest",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        return value
    }
}
extension ComponentStore {
    static func encodeProbe(_ document: RoadmapDocument) -> ComponentKind? {
        guard let data = try? document.encoded() else { return nil }
        return (try? JSONDecoder().decode(ComponentInstance.self,from:data))?.component
    }
}
