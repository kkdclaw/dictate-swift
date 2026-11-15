import XCTest
@testable import DictateCore

final class CommandsTests: XCTestCase {
    func make(_ json: String) throws -> Commands {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return Commands(url: url)
    }

    func testWholeAndTail() throws {
        let c = try make(#"{"snippets": {"моя почта": "a@b.c"}}"#)
        XCTAssertEqual(c.match("Удали.")?.id, "delete_line")
        XCTAssertEqual(c.match("Отправь!")?.head, "")
        let t = c.match("Созвон переносим на завтра, отправь.")
        XCTAssertEqual(t?.id, "send"); XCTAssertEqual(t?.head, "Созвон переносим на завтра")
        XCTAssertNil(c.match("Удали файл и перезапусти"))          // внутри текста — не команда
        XCTAssertNil(c.match("Это надо сначала, удали"))             // «удали» хвостом не работает
        let s = c.match("Пиши на, моя почта")
        XCTAssertEqual(s?.snippet, "a@b.c"); XCTAssertEqual(s?.head, "Пиши на")
        XCTAssertEqual(c.match("Моя почта.")?.snippet, "a@b.c")
        XCTAssertEqual(c.match("Удали всё")?.id, "delete_all")      // ё→е
        XCTAssertEqual(c.match("текст, новая строка")?.id, "new_line")  // длиннее совпадение точнее
    }

    func testUserLayer() throws {
        let c = try make(#"{"phrases": {"enter": ["enter", "энтер"]}, "disabled": ["copy"]}"#)
        XCTAssertEqual(c.match("Enter.")?.id, "enter")
        XCTAssertNil(c.match("Скопируй"))
        XCTAssertTrue(c.describeAll().contains("enter / энтер"))
    }

    func testGuards() {
        XCTAssertTrue(Guards.isDictionaryEcho("GitHub, ZeroTier.", hint: "GitHub, ZeroTier, launchd, задеплоить."))
        XCTAssertFalse(Guards.isDictionaryEcho("ZeroTier", hint: "GitHub, ZeroTier"))
        XCTAssertNotNil(Guards.wordLoop(String(repeating: "да ", count: 10)))
        XCTAssertNil(Guards.wordLoop("обычная фраза из нескольких слов без повторов вообще"))
        XCTAssertEqual(Guards.stripShortPeriod("На мини."), "На мини")
        XCTAssertEqual(Guards.stripShortPeriod("Первое. Второе."), "Первое. Второе.")
    }
}
