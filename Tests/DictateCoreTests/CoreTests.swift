import XCTest
@testable import DictateCore

final class HotkeyTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(HotkeySpec.parse("alt_r")?.keyCode, 0x3D)
        XCTAssertEqual(HotkeySpec.parse("alt_r")?.isModifierOnly, true)
        XCTAssertEqual(HotkeySpec.parse("fn")?.deviceMask, HotkeySpec.secondaryFn)
        let c = HotkeySpec.parse("ctrl+space")!
        XCTAssertEqual(c.keyCode, 0x31); XCTAssertEqual(c.mods, HotkeySpec.ctrl); XCTAssertEqual(c.label, "⌃Space")
        let d = HotkeySpec.parse("cmd+shift+d")!
        XCTAssertEqual(d.keyCode, 0x02); XCTAssertEqual(d.mods, HotkeySpec.cmd | HotkeySpec.shift); XCTAssertEqual(d.label, "⇧⌘D")
        XCTAssertEqual(HotkeySpec.parse("f13")?.keyCode, 0x69)
        XCTAssertNil(HotkeySpec.parse("hyper+x"))
    }
    func testSpecFromPress() {
        XCTAssertEqual(HotkeySpec.specFromPress(code: 0x3D, flags: 0), "alt_r")
        XCTAssertEqual(HotkeySpec.specFromPress(code: 0x31, flags: HotkeySpec.ctrl), "ctrl+space")
        XCTAssertEqual(HotkeySpec.specFromPress(code: 0x02, flags: HotkeySpec.cmd | HotkeySpec.shift), "shift+cmd+d")
        XCTAssertEqual(HotkeySpec.specFromPress(code: 0x69, flags: 0), "f13")
        XCTAssertNil(HotkeySpec.specFromPress(code: 0x02, flags: 0))   // голая буква
        XCTAssertNil(HotkeySpec.specFromPress(code: 0x31, flags: 0))   // голый пробел
        XCTAssertEqual(HotkeySpec.parse("shift+cmd+d")?.label, "⇧⌘D")
        XCTAssertEqual(HotkeySpec.heldDescription(code: 0x02, flags: HotkeySpec.cmd), "⌘ D")
    }
}

final class TermsTests: XCTestCase {
    func testOrderDedupBudget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("terms.d"), withIntermediateDirectories: true)
        try "launchd\nGitHub\n".write(to: dir.appendingPathComponent("terms.d/dev.txt"), atomically: true, encoding: .utf8)
        try "# комментарий\ngithub\nGuesta\nTokeet\n".write(to: dir.appendingPathComponent("terms.txt"), atomically: true, encoding: .utf8)
        let t = Terms(dataDir: dir)
        XCTAssertEqual(t.layers(), ["dev"])
        XCTAssertEqual(t.layer(for: "iTerm2", profiles: ["iTerm2": "dev"], defaultLayer: ""), "dev")
        XCTAssertEqual(t.layer(for: "Telegram", profiles: ["iTerm2": "dev"], defaultLayer: "chat"), "")  // слоя chat нет
        let count: (String) -> Int = { $0.count }  // «токен» = символ
        XCTAssertEqual(t.load(layer: "dev", count: count), "launchd, GitHub, Guesta, Tokeet")
        XCTAssertEqual(t.load(layer: "dev", budget: 20, count: count), "launchd, GitHub")
        XCTAssertEqual(t.hint(layer: "", count: count), "github, Guesta, Tokeet, задеплоить.")
    }
}
