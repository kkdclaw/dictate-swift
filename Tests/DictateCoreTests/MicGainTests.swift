import Foundation
import XCTest
@testable import DictateCore

final class MicGainTests: XCTestCase {
    func testFixedFromConfig() {
        XCTAssertNil(MicGain.fixed(nil))
        XCTAssertNil(MicGain.fixed("auto"))
        XCTAssertEqual(MicGain.fixed(4.0), 4)
        XCTAssertEqual(MicGain.fixed(8), 8)
        XCTAssertEqual(MicGain.fixed(NSNumber(value: 2)), 2)   // так число приходит из config.json
        XCTAssertEqual(MicGain.fixed(0.0), 1)                  // меньше единицы не бывает: ослаблять нечем
        XCTAssertEqual(MicGain.fixed(1000), 64)
    }

    /// Авто: тихий микрофон (пик речи 0,012–0,03) проходит и подтягивается к 0,25; мёртвый вход — пусто.
    func testAutoQuietMic() {
        for peak: Float in [0.0118, 0.0177, 0.0183, 0.027, 0.034] {
            XCTAssertFalse(MicGain.isEmpty(peak: peak, fixed: nil), "пик \(peak)")
            XCTAssertEqual(MicGain.factor(peak: peak, fixed: nil) * peak, MicGain.targetPeak, accuracy: 0.001)
        }
        XCTAssertTrue(MicGain.isEmpty(peak: 0.0007, fixed: nil))   // случайное нажатие в тишине
        XCTAssertTrue(MicGain.isEmpty(peak: 0.0024, fixed: nil))   // шумовой пол уснувшей гарнитуры
        XCTAssertEqual(MicGain.factor(peak: 0.0024, fixed: nil), 1)
    }

    /// Авто: обычный микрофон не трогаем, совсем тихое — не больше потолка.
    func testAutoLimits() {
        XCTAssertEqual(MicGain.factor(peak: 0.25, fixed: nil), 1)
        XCTAssertEqual(MicGain.factor(peak: 0.6, fixed: nil), 1)
        XCTAssertEqual(MicGain.factor(peak: 0.005, fixed: nil), MicGain.maxAuto)
    }

    /// Постоянный множитель: порог пустого захвата прежний, но по усиленному сигналу; ×1 — поведение до 0.8.
    func testFixed() {
        XCTAssertTrue(MicGain.isEmpty(peak: 0.0183, fixed: 1))
        XCTAssertFalse(MicGain.isEmpty(peak: 0.02, fixed: 1))
        XCTAssertFalse(MicGain.isEmpty(peak: 0.0118, fixed: 8))
        XCTAssertTrue(MicGain.isEmpty(peak: 0.0007, fixed: 8))
        XCTAssertEqual(MicGain.factor(peak: 0.5, fixed: 8), 8)
        XCTAssertEqual(MicGain.factor(peak: 0.01, fixed: 1), 1)
    }

    func testAmplified() {
        XCTAssertEqual(MicGain.amplified([0.125, -0.25, 0], by: 2), [0.25, -0.5, 0])
        XCTAssertEqual(MicGain.amplified([0.5, -0.5], by: 4), [1, -1])       // срез, а не переполнение
        XCTAssertEqual(MicGain.amplified([0.3], by: 1), [0.3])
        XCTAssertEqual(MicGain.peak([0.1, -0.4, 0.2]), 0.4)
    }

    func testLearn() {
        XCTAssertEqual(MicGain.learn(old: nil, recording: 9.3), 9.3)
        XCTAssertEqual(MicGain.learn(old: 9, recording: 9), 9, accuracy: 0.001)
        let moved = MicGain.learn(old: 9, recording: 1)       // микрофон стал громким — шкала сходится к ×1
        XCTAssertTrue(moved > 1 && moved < 9)
        XCTAssertEqual(MicGain.learn(old: nil, recording: 100), MicGain.maxAuto)
    }

    func testLabel() {
        XCTAssertEqual(MicGain.label(8), "×8")
        XCTAssertEqual(MicGain.label(9.26), "×9.3")
        XCTAssertEqual(MicGain.label(2.5), "×2.5")
        XCTAssertEqual(MicGain.label(21.2), "×21")
    }
}
