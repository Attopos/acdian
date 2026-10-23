import Foundation

/// Chinese source strings are stable keys. Interpolated UI uses printf placeholders
/// (%@ for localized strings, %d for integers), never interpolated lookup keys.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var name: String {
        switch self { case .english: return "English"; case .spanish: return "Español"; case .simplifiedChinese: return "简体中文" }
    }
    var locale: Locale { Locale(identifier:rawValue) }
    static func stored(in preferences: UserDefaults = .standard) -> AppLanguage {
        preferences.string(forKey:"appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
    func localized(_ source: String, arguments: [CVarArg] = []) -> String {
        let translation = Self.translations[source]
        let format: String
        switch self { case .english: format = translation?.english ?? source; case .spanish: format = translation?.spanish ?? source; case .simplifiedChinese: format = source }
        return arguments.isEmpty ? format : String(format:format,locale:locale,arguments:arguments)
    }
    func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
    func noteCount(_ count: Int) -> String { count == 1 ? localized("1 篇笔记") : localized("%@ 篇笔记",arguments:[number(count)]) }
    func fileCount(_ count: Int) -> String { count == 1 ? localized("1 个文件") : localized("%@ 个文件",arguments:[number(count)]) }
    func characterCount(_ count: Int) -> String { count == 1 ? localized("1 字符") : localized("%@ 字符",arguments:[number(count)]) }
    func remainingTrashDays(_ count: Int) -> String { count == 1 ? localized("剩余 1 天") : localized("剩余 %@ 天",arguments:[number(count)]) }
    func modifiedDate(_ date: Date) -> String { date.formatted(.dateTime.month().day().locale(locale)) }
    func time(_ date: Date) -> String { date.formatted(Date.FormatStyle(date:.omitted,time:.shortened).locale(locale)) }

    private static let translations: [String:(english:String,spanish:String)] = [
        "好": ("OK", "Aceptar"),
        "页面": ("Pages", "Páginas"),
        "所有页面": ("All pages", "Todas las páginas"),
        "新建页面": ("New page", "Nueva página"),
        "新建页面 ⌘N": ("New page ⌘N", "Nueva página ⌘N"),
        "保存页面": ("Save page", "Guardar página"),
        "搜索页面与内容": ("Search pages and content", "Buscar páginas y contenido"),
        "搜索页面": ("Search pages", "Buscar páginas"),
        "刷新页面": ("Refresh pages", "Actualizar páginas"),
        "删除": ("Delete", "Eliminar"),
        "移到垃圾桶": ("Move to Trash", "Mover a la papelera"),
        "垃圾桶": ("Trash", "Papelera"),
        "恢复": ("Restore", "Restaurar"),
        "删除于 %@": ("Deleted on %@", "Eliminado el %@"),
        "将在 %@ 后彻底删除": ("Permanently deleted after %@", "Se eliminará permanentemente después de %@"),
        "垃圾桶是空的": ("Trash is empty", "La papelera está vacía"),
        "删除的文件会保留 15 天，之后自动彻底删除。": ("Deleted files are kept for 15 days, then automatically deleted permanently.", "Los archivos eliminados se conservan durante 15 días y después se eliminan permanentemente de forma automática."),
        "剩余 %@ 天": ("%@ days remaining", "Quedan %@ días"),
        "剩余 1 天": ("1 day remaining", "Queda 1 día"),
        "文件已移到垃圾桶": ("Moved to Trash", "Movido a la papelera"),
        "文件已恢复": ("File restored", "Archivo restaurado"),
        "无法安全访问垃圾桶。": ("Trash could not be accessed safely.", "No se pudo acceder a la papelera de forma segura."),
        "垃圾桶项目无效或已损坏。": ("This Trash item is invalid or damaged.", "Este elemento de la papelera no es válido o está dañado."),
        "找不到垃圾桶项目。": ("This Trash item could not be found.", "No se pudo encontrar este elemento de la papelera."),
        "此项目已超过 15 天保留期限，无法恢复。": ("This item has passed the 15-day retention period and cannot be restored.", "Este elemento ha superado el plazo de conservación de 15 días y no se puede restaurar."),
        "删除尚未完成，文件已保留在垃圾桶中。": ("Deletion has not finished. The file has been kept in Trash.", "La eliminación no ha finalizado. El archivo se ha conservado en la papelera."),
        "新建笔记": ("New note", "Nueva nota"),
        "页面会保存在 acdian 中。": ("Your page will be saved in acdian.", "Tu página se guardará en acdian."),
        "笔记名称": ("Note name", "Nombre de la nota"),
        "取消": ("Cancel", "Cancelar"),
        "创建": ("Create", "Crear"),
        "显示或隐藏侧栏": ("Show or hide sidebar", "Mostrar u ocultar la barra lateral"),
        "尚未保存": ("Unsaved", "Sin guardar"),
        "插入附件": ("Insert attachment", "Insertar archivo adjunto"),
        "保存 ⌘S": ("Save ⌘S", "Guardar ⌘S"),
        "文章目录": ("Outline", "Índice"),
        "增大字号": ("Increase text size", "Aumentar el tamaño del texto"),
        "减小字号": ("Decrease text size", "Reducir el tamaño del texto"),
        "重新载入文件": ("Reload file", "Volver a cargar el archivo"),
        "在 Finder 中显示": ("Show in Finder", "Mostrar en Finder"),
        "上一页": ("Previous page", "Página anterior"),
        "下一页": ("Next page", "Página siguiente"),
        "缩小": ("Zoom out", "Alejar"),
        "放大": ("Zoom in", "Acercar"),
        "这篇笔记还没有标题": ("This note has no headings yet", "Esta nota aún no tiene títulos"),
        "此类文件可在系统默认应用中打开。": ("Open this file in its default application.", "Abre este archivo en su aplicación predeterminada."),
        "打开文件": ("Open file", "Abrir archivo"),
        "有未保存的修改": ("Unsaved changes", "Cambios sin guardar"),
        "%@ 字符": ("%@ characters", "%@ caracteres"),
        "1 字符": ("1 character", "1 carácter"),
        "%@ 个文件": ("%@ files", "%@ archivos"),
        "1 个文件": ("1 file", "1 archivo"),
        "%@ 篇笔记": ("%@ notes", "%@ notas"),
        "1 篇笔记": ("1 note", "1 nota"),
        "搜索笔记与内容": ("Search notes and content", "Buscar notas y contenido"),
        "清除搜索": ("Clear search", "Borrar búsqueda"),
        "所有笔记": ("All notes", "Todas las notas"),
        "搜索结果 · %@": ("Search results · %@", "Resultados · %@"),
        "刷新文件目录": ("Refresh file list", "Actualizar la lista de archivos"),
        "新建笔记 ⌘N": ("New note ⌘N", "Nueva nota ⌘N"),
        "没有找到匹配的文件": ("No matching files", "No se encontraron archivos"),
        "正在读取文件…": ("Reading files…", "Leyendo archivos…"),
        "最近修改": ("Recently modified", "Modificadas recientemente"),
        "暂无 Markdown 笔记": ("No Markdown notes yet", "Aún no hay notas Markdown"),
        "语言": ("Language", "Idioma"),
        "语言：%@": ("Language: %@", "Idioma: %@"),
        "保存笔记": ("Save note", "Guardar nota"),
        "插入附件…": ("Insert attachment…", "Insertar archivo adjunto…"),
        "视图": ("View", "Visualización"),
        "无法把“%@”移动到它自己里面。": ("“%@” can’t be moved into itself.", "No se puede mover “%@” dentro de sí mismo."),
        "外观": ("Appearance", "Apariencia"),
        "跟随系统": ("Follow System", "Según el sistema"),
        "浅色": ("Light", "Claro"),
        "深色": ("Dark", "Oscuro"),
        "显示或隐藏目录": ("Show or hide outline", "Mostrar u ocultar el índice"),
        "关于 acdian": ("About acdian", "Acerca de acdian"),
        "本地 Markdown 阅读器": ("Local Markdown reader", "Lector local de Markdown"),
        "就绪": ("Ready", "Listo"),
        "正在读取页面…": ("Reading pages…", "Leyendo páginas…"),
        "页面已刷新": ("Pages refreshed", "Páginas actualizadas"),
        "正在打开 %@…": ("Opening %@…", "Abriendo %@…"),
        "正在保存…": ("Saving…", "Guardando…"),
        "无法自动保存": ("Could not save automatically", "No se pudo guardar automáticamente"),
        "已保存 · %@": ("Saved · %@", "Guardado · %@"),
        "保存对“%@”的修改？": ("Save changes to “%@”?", "¿Guardar los cambios en «%@»?"),
        "笔记": ("note", "nota"),
        "保存后会更新原 Markdown 文件。": ("Saving updates the original Markdown file.", "Al guardar se actualizará el archivo Markdown original."),
        "保存": ("Save", "Guardar"),
        "不保存": ("Don’t save", "No guardar"),
        "编辑器仍在切换笔记，请稍后重试。": ("The editor is still switching notes. Try again shortly.", "El editor aún está cambiando de nota. Inténtalo de nuevo en unos instantes."),
        "无法读取编辑器中的最新内容，已取消操作。\n%@": ("Could not read the latest editor content. The action was cancelled.\n%@", "No se pudo leer el contenido más reciente del editor. Se canceló la operación.\n%@"),
        "编辑器响应超时，请稍后重试。": ("The editor timed out. Try again shortly.", "El editor tardó demasiado en responder. Inténtalo de nuevo en unos instantes."),
        "文件较大，无法作为文本打开。": ("This file is too large to open as text.", "El archivo es demasiado grande para abrirlo como texto."),
        "放弃本地修改并重新载入？": ("Discard local changes and reload?", "¿Descartar los cambios locales y volver a cargar?"),
        "未保存的修改将丢失，重新读取磁盘中的最新文件。": ("Unsaved changes will be lost. The latest file will be read from disk.", "Se perderán los cambios sin guardar y se leerá la versión más reciente del archivo en disco."),
        "重新载入": ("Reload", "Volver a cargar"),
        "找不到链接的文件：%@\n请检查文件路径；同名文件请使用完整路径。": ("Linked file not found: %@\nCheck the path. For files with the same name, use the full path.", "No se encontró el archivo enlazado: %@\nComprueba la ruta. Si hay archivos con el mismo nombre, usa la ruta completa."),
        "请输入有效的笔记名称，不包含 / 或 :。": ("Enter a valid note name without / or :.", "Introduce un nombre de nota válido que no contenga / ni :."),
        "请输入有效的页面名称，不包含 / 或 :。": ("Enter a valid page name without / or :.", "Introduce un nombre de página válido que no contenga / ni :."),
        "附件会复制到页面的 Attachments 文件夹，并插入链接。": ("Attachments will be copied to the page’s Attachments folder and inserted as links.", "Los archivos adjuntos se copiarán en la carpeta Attachments de la página y se insertarán como enlaces."),
        "附件目录指向页面存储范围以外，无法导入。": ("The attachments folder points outside page storage. Import was cancelled.", "La carpeta de archivos adjuntos apunta fuera de la ubicación de las páginas. Se canceló la importación."),
        "无法打开页面文件夹：%@": ("Could not open the pages folder: %@", "No se pudo abrir la carpeta de páginas: %@"),
        "“%@”不是 UTF-8 文本，无法安全编辑。": ("“%@” is not UTF-8 text and cannot be edited safely.", "«%@» no es texto UTF-8 y no se puede editar de forma segura."),
        "“%@”已被其他应用修改。请重新载入后再保存，避免覆盖外部修改。": ("“%@” was changed by another application. Reload before saving to preserve those changes.", "Otra aplicación modificó «%@». Vuelve a cargarlo antes de guardar para conservar esos cambios."),
        "“%@”指向页面存储位置以外，已停止读取或保存。": ("“%@” points outside page storage. Reading or saving was stopped.", "«%@» apunta fuera de la ubicación de las páginas. Se detuvo la lectura o el guardado."),
        "编辑器加载失败，请重新载入文件。\n%@": ("The editor could not load. Reload the file.\n%@", "No se pudo cargar el editor. Vuelve a cargar el archivo.\n%@"),
        "附件链接插入失败：%@": ("Could not insert attachment links: %@", "No se pudieron insertar los enlaces de los archivos adjuntos: %@"),
        "无法读取 PDF，文件可能已损坏或受密码保护。": ("Could not read the PDF. It may be damaged or password protected.", "No se pudo leer el PDF. Puede estar dañado o protegido con contraseña."),
        "适应窗口": ("Fit to window", "Ajustar a la ventana"),
        "无法预览图片": ("Cannot preview image", "No se puede mostrar la imagen"),
        "文件格式可能不受当前 macOS 支持。": ("This file format may not be supported by this version of macOS.", "Es posible que esta versión de macOS no admita el formato del archivo.")
    ]
}

enum AppStatus {
    case ready, readingPages, openedPages(Int), refreshed, trashed, restored, opening(String), saving, saveFailed, saved(Date), path(String)
    func localized(_ language: AppLanguage) -> String {
        switch self {
        case .ready: return language.localized("就绪")
        case .readingPages: return language.localized("正在读取页面…")
        case .openedPages: return language.localized("就绪")
        case .refreshed: return language.localized("页面已刷新")
        case .trashed: return language.localized("文件已移到垃圾桶")
        case .restored: return language.localized("文件已恢复")
        case .opening(let name): return language.localized("正在打开 %@…",arguments:[name])
        case .saving: return language.localized("正在保存…")
        case .saveFailed: return language.localized("无法自动保存")
        case .saved(let date): return language.localized("已保存 · %@",arguments:[language.time(date)])
        case .path(let path): return path
        }
    }
}
