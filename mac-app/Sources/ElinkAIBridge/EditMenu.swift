import AppKit

/// 面板里那些输入框的复制粘贴。
///
/// macOS 把 Cmd+C/V/X/A/Z 的分发挂在主菜单上：`NSApplication` 收到按键后先让
/// `mainMenu` 匹配 key equivalent，命中才把对应的 `paste:` 之类发给第一响应者。
/// 没有主菜单就没有这一步，`NSTextField` 永远收不到那条 action——每个输入框都只能
/// 手打。这个 app 是 `.accessory`（`LSUIElement`），从不显示菜单栏，于是这一整套
/// 默认行为跟着一起消失了，直到有人要往框里粘一个 64 字符的 API key。
///
/// 这份菜单永远不会被看见，它存在的唯一理由就是给这些快捷键一个挂载点。
enum EditMenu {
    /// 只做编辑这一组。不放「退出」：面板底部已经有退出按钮，凭空多一个 Cmd+Q
    /// 会让一个不显示菜单栏的应用多出一条看不见的退出路径。
    static func install(into app: NSApplication) {
        let main = NSMenu()
        let item = NSMenuItem()
        item.submenu = makeEditMenu()
        main.addItem(item)
        app.mainMenu = main
    }

    static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: tr("编辑", "Edit"))
        // 标题在这个应用里永远不显示，但 selector 和快捷键必须与系统标准一致：
        // 第一响应者能不能响应，靠的就是这几个 selector 名字。
        let entries: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            (tr("撤销", "Undo"), Selector(("undo:")), "z", .command),
            (tr("重做", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            (tr("剪切", "Cut"), #selector(NSText.cut(_:)), "x", .command),
            (tr("拷贝", "Copy"), #selector(NSText.copy(_:)), "c", .command),
            (tr("粘贴", "Paste"), #selector(NSText.paste(_:)), "v", .command),
            (tr("全选", "Select All"), #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, modifiers) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        return menu
    }
}
