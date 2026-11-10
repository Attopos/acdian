import Foundation
import SQLite3

/// A derived cache of every page's title, card note and folded text, with a
/// trigram full-text index so Chinese substrings match. It lives in Application
/// Support, never in the pages folder, and deleting it only means rebuilding it.
final class PageDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private(set) var fullText = false
    private static let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)

    init?(root: URL) {
        let file = IndexSnapshot.file(root:root,name:"pages.sqlite")
        guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("CREATE TABLE IF NOT EXISTS pages(path TEXT PRIMARY KEY, title TEXT, mtime REAL, size INTEGER, note TEXT, body TEXT)")
        // Trigram FTS needs SQLite 3.34; without it, search scans the body column.
        fullText = exec("CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(path UNINDEXED, title, body, content='pages', content_rowid='rowid', tokenize='trigram')")
        if fullText {
            exec("""
            CREATE TRIGGER IF NOT EXISTS pages_ai AFTER INSERT ON pages BEGIN INSERT INTO pages_fts(rowid,path,title,body) VALUES (new.rowid,new.path,new.title,new.body); END;
            CREATE TRIGGER IF NOT EXISTS pages_ad AFTER DELETE ON pages BEGIN INSERT INTO pages_fts(pages_fts,rowid,path,title,body) VALUES('delete',old.rowid,old.path,old.title,old.body); END;
            CREATE TRIGGER IF NOT EXISTS pages_au AFTER UPDATE ON pages BEGIN INSERT INTO pages_fts(pages_fts,rowid,path,title,body) VALUES('delete',old.rowid,old.path,old.title,old.body); INSERT INTO pages_fts(rowid,path,title,body) VALUES (new.rowid,new.path,new.title,new.body); END;
            """)
        }
    }
    deinit { sqlite3_close(db) }

    @discardableResult private func exec(_ sql: String) -> Bool { sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK }
    private func rows(_ sql: String, _ bind: [String] = [], _ row: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        for (i,value) in bind.enumerated() { sqlite3_bind_text(statement,Int32(i + 1),value,-1,Self.transient) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }
    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement,column).map { String(cString:$0) } ?? "" }

    /// What each page looked like when it was last read, to skip unchanged ones.
    func stamps() -> [String:(mtime: Double, size: Int)] {
        var result: [String:(mtime: Double, size: Int)] = [:]
        rows("SELECT path, mtime, size FROM pages") { result[Self.text($0,0)] = (sqlite3_column_double($0,1),Int(sqlite3_column_int64($0,2))) }
        return result
    }
    struct Row { let path, title, note, body: String; let mtime: Double; let size: Int }
    /// Writes a batch in one transaction and removes pages that are gone.
    func apply(upserts: [Row], deletions: [String]) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db,"INSERT INTO pages(path,title,mtime,size,note,body) VALUES(?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET title=excluded.title,mtime=excluded.mtime,size=excluded.size,note=excluded.note,body=excluded.body",-1,&statement,nil) == SQLITE_OK, let statement {
            for row in upserts {
                sqlite3_bind_text(statement,1,row.path,-1,Self.transient); sqlite3_bind_text(statement,2,row.title,-1,Self.transient)
                sqlite3_bind_double(statement,3,row.mtime); sqlite3_bind_int64(statement,4,Int64(row.size))
                sqlite3_bind_text(statement,5,row.note,-1,Self.transient); sqlite3_bind_text(statement,6,row.body,-1,Self.transient)
                sqlite3_step(statement); sqlite3_reset(statement)
            }
            sqlite3_finalize(statement)
        }
        if sqlite3_prepare_v2(db,"DELETE FROM pages WHERE path = ?",-1,&statement,nil) == SQLITE_OK, let statement {
            for path in deletions { sqlite3_bind_text(statement,1,path,-1,Self.transient); sqlite3_step(statement); sqlite3_reset(statement) }
            sqlite3_finalize(statement)
        }
        exec("COMMIT")
    }
    var count: Int { var n = 0; rows("SELECT count(*) FROM pages") { n = Int(sqlite3_column_int64($0,0)) }; return n }
    /// Paths whose folded title or text contains `folded`.
    func search(_ folded: String, prefix: String?, limit: Int = 500) -> [String] {
        var result: [String] = []
        let scope = (prefix ?? "") + "%"
        if fullText, folded.count >= 3 {
            let phrase = "\"" + folded.replacingOccurrences(of:"\"",with:"\"\"") + "\""
            rows("SELECT path FROM pages_fts WHERE pages_fts MATCH ? AND path LIKE ? LIMIT \(limit)",[phrase,scope]) { result.append(Self.text($0,0)) }
        } else {
            // Shorter than a trigram: a plain scan, still fast for ten thousand small pages.
            rows("SELECT path FROM pages WHERE path LIKE ? AND (instr(title,?) > 0 OR instr(body,?) > 0) LIMIT \(limit)",[scope,folded,folded]) { result.append(Self.text($0,0)) }
        }
        return result
    }
    /// Card notes for every page under a folder.
    func notes(prefix: String) -> [String:String] {
        var result: [String:String] = [:]
        rows("SELECT path, note FROM pages WHERE path LIKE ?",[prefix + "%"]) { result[Self.text($0,0)] = Self.text($0,1) }
        return result
    }
}
