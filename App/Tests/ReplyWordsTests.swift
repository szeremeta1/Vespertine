import Foundation
import Testing
import VespertineStreamServer
@testable import Vespertine

/// A phone is answered in its own language where the Mac has it: what the Mac refuses is shown on the phone as it is.
struct ReplyWordsTests {
    private let shipped = ["en", "de", "fr", "pt-BR", "pt-PT", "zh-Hans", "zh-Hant", "zh-HK", "uk", "nb"]

    @Test func thePhonesLanguageIsMatchedToOneTheMacHas() {
        #expect(ReplyWords.localization(for: "de", available: shipped) == "de")
        #expect(ReplyWords.localization(for: "pt-BR", available: shipped) == "pt-BR")
        #expect(ReplyWords.localization(for: "pt_BR", available: shipped) == "pt-BR")
        #expect(ReplyWords.localization(for: "de-AT", available: shipped) == "de")
        #expect(ReplyWords.localization(for: "zh-Hans", available: shipped) == "zh-Hans")
    }

    @Test func aLanguageTheMacDoesNotHaveLeavesTheMacsOwn() {
        #expect(ReplyWords.localization(for: "ru", available: shipped) == nil)
        #expect(ReplyWords.localization(for: nil, available: shipped) == nil)
        #expect(ReplyWords.localization(for: "", available: shipped) == nil)
    }

    @Test func whatAPhoneSendsIsNeverUsedAsAPath() {
        #expect(ReplyWords.localization(for: "../../etc", available: shipped) == nil)
        #expect(ReplyWords.localization(for: "de/../fr", available: shipped) == nil)
        #expect(ReplyWords.localization(for: String(repeating: "a", count: 200), available: shipped) == nil)
    }

    @Test func aRefusalIsWordedInTheLanguageBeingAnswered() {
        let english = ReplyWords.speaking("en") { ReplyWords.stream(.tooManyChannels(12, most: 8)) }
        #expect(english.contains("12") && english.contains("8"))
        let german = ReplyWords.speaking("de") { ReplyWords.stream(.tooManyChannels(12, most: 8)) }
        #expect(german.contains("12") && german.contains("8"))
        #expect(german != english)
        // Around a command, the kit's own refusals come out the same way.
        #expect(ReplyWords.speaking("de") { StreamWords.say(.streamingOff) } == ReplyWords.speaking("de") { ReplyWords.stream(.streamingOff) })
        #expect(ReplyWords.speaking("de") { StreamWords.say(.streamingOff) } != StreamRefusal.streamingOff.english)
    }
}
