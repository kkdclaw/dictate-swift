// Порт test_textclean.py Python-версии: правила чистки те же.
import XCTest
@testable import DictateCore

final class TextCleanTests: XCTestCase {
    func keep(_ t: String, _ s: [Segment]? = nil, line: UInt = #line) {
        let (out, cut) = TextClean.stripLoops(t, segments: s)
        XCTAssertEqual(out, t, line: line); XCTAssertTrue(cut.isEmpty, "\(cut)", line: line)
    }
    func cuts(_ t: String, _ expect: String, _ s: [Segment]? = nil, line: UInt = #line) {
        let (out, cut) = TextClean.stripLoops(t, segments: s)
        XCTAssertEqual(out, expect, line: line); XCTAssertFalse(cut.isEmpty, line: line)
    }

    func testRealRepeatsKept() {
        keep("нет нет нет нет нет, я не согласен")
        keep("ха-ха-ха-ха-ха, смешно")
        keep("1 000 000 000 000 рублей")
        keep("да да да да да да да, точно")
    }
    func testLoopsCut() {
        cuts(String(repeating: "ratos", count: 40) + " нормальная речь", "нормальная речь")
        cuts("начало фразы secular " + String(repeating: "secular ", count: 20) + "конец", "начало фразы конец")
        cuts(String(repeating: "ха", count: 30) + " ладно", "ладно")
    }
    func testTitles() {
        cuts("Обзор новой модели. Спасибо за просмотр!", "Обзор новой модели.")
        keep("Ок, продолжение следует на следующей неделе")
        keep("Спасибо за просмотр этого длинного отчёта, коллеги")
        keep("Спасибо за просмотр!")
        cuts("Текст доклада. Продолжение следует. Субтитры сделал DimaTorzok", "Текст доклада.")
    }
    func testTitleAudioGate() {
        keep("Это первая часть письма, продолжение следует.",
             [Segment(text: " Это первая часть письма, продолжение следует.", start: 0, end: 3, noSpeechProb: 0.02, avgLogprob: -0.2)])
        var segs = [Segment(text: " Обзор новой модели.", start: 0, end: 2, noSpeechProb: 0.02, avgLogprob: -0.2),
                    Segment(text: " Спасибо за просмотр!", start: 2.1, end: 3.5, noSpeechProb: 0.7, avgLogprob: -0.9)]
        cuts("Обзор новой модели. Спасибо за просмотр!", "Обзор новой модели.", segs)
        segs[1].noSpeechProb = 0.1; segs[1].start = 5.0
        cuts("Обзор новой модели. Спасибо за просмотр!", "Обзор новой модели.", segs)
        segs[1].start = 2.1; segs[1].avgLogprob = -0.2
        keep("Обзор новой модели. Спасибо за просмотр!", segs)
    }
}
