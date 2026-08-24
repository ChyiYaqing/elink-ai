import AppKit
import XCTest
@testable import ElinkAIBridge

/// 面板输入框的复制粘贴依赖主菜单存在，而这个应用不显示菜单栏——没有任何 UI 会
/// 暴露它坏掉了。这组测试盯的就是那几个 selector 和快捷键。
final class EditMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        super.tearDown()
    }

    /// selector 名字必须与系统标准一致：第一响应者能不能响应，靠的就是这几个名字。
    /// 拼错一个字母不会有编译错误，只会让那个快捷键静默失效。
    func testEditMenuBindsTheStandardResponderActions() {
        let menu = EditMenu.makeEditMenu()
        let bindings = Dictionary(
            menu.items.map { ($0.keyEquivalent, ($0.action, $0.keyEquivalentModifierMask)) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(bindings["c"]?.0, #selector(NSText.copy(_:)))
        XCTAssertEqual(bindings["v"]?.0, #selector(NSText.paste(_:)))
        XCTAssertEqual(bindings["x"]?.0, #selector(NSText.cut(_:)))
        XCTAssertEqual(bindings["a"]?.0, #selector(NSText.selectAll(_:)))
        XCTAssertEqual(bindings["c"]?.1, .command)
    }

    /// 撤销与重做共用一个键，靠 Shift 区分；两条都写成 Cmd+Z 会让重做永远匹配不到。
    func testUndoAndRedoAreDistinguishedByShift() {
        let menu = EditMenu.makeEditMenu()
        let zItems = menu.items.filter { $0.keyEquivalent == "z" }
        XCTAssertEqual(zItems.count, 2)
        XCTAssertEqual(Set(zItems.map(\.keyEquivalentModifierMask.rawValue)),
                       [NSEvent.ModifierFlags.command.rawValue,
                        NSEvent.ModifierFlags([.command, .shift]).rawValue])
    }

    /// 不放退出：面板底部已经有退出按钮，一个不显示菜单栏的应用不该多出一条
    /// 看不见的 Cmd+Q 退出路径。
    func testEditMenuCarriesNothingButEditing() {
        let actions = EditMenu.makeEditMenu().items.compactMap(\.action)
        XCTAssertEqual(actions.count, 6)
        XCTAssertFalse(actions.contains(#selector(NSApplication.terminate(_:))))
    }

    /// 缺失的那一环是「有没有人认领 Cmd+V」：没有主菜单时无人认领，按键就此消失，
    /// 输入框永远等不到 `paste:`。装上菜单之后它被认领——这正是修复的全部内容。
    ///
    /// 到此为止：再往后那一步（把 action 送到第一响应者）在 `swift test` 里验不了。
    /// 测试进程没有 GUI 会话，`NSApp.keyWindow` 始终是 nil，`targetForAction` 因而
    /// 找不到任何响应者链。断言那一步只会测出测试环境的限制，而不是这段代码的对错。
    func testTheMenuIsWhatClaimsCommandV() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        ))
        XCTAssertFalse(NSMenu().performKeyEquivalent(with: event),
                       "没有菜单时按键无人认领，这就是此前每个输入框的处境")
        XCTAssertTrue(EditMenu.makeEditMenu().performKeyEquivalent(with: event),
                      "装上之后必须被认领")
    }

    /// 装上之后必须真的挂在 mainMenu 上——install 少写一行同样没有任何 UI 会报警。
    func testInstallAttachesTheMenuToTheApplication() {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }

        app.mainMenu = nil
        EditMenu.install(into: app)
        let submenu = try? XCTUnwrap(app.mainMenu?.items.first?.submenu)
        XCTAssertEqual(submenu?.items.count, 6)
    }
}
