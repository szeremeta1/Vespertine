//
// Vespertine: the language a phone is answered in. A refusal ("That output isn’t connected to this Mac.") is shown on the phone
// as it is, so it is worded in the phone's language where this Mac has it, not in the Mac's own.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import VespertineStreamServer

nonisolated enum ReplyWords {
    /// The language of the phone being answered ("de", "pt-BR"); nil: the Mac's own.
    @TaskLocal static var language: String?

    /// The localization of `available` that serves a phone showing `language`: the same one, its base language, or the
    /// nearest the system knows; nil when there is none (the Mac's own language is used then).
    static func localization(for language: String?, available: [String]) -> String? {
        guard let language = language?.trimmingCharacters(in: .whitespaces), !language.isEmpty, language.count <= 35,
              language.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let wanted = language.replacingOccurrences(of: "_", with: "-")
        if let exact = available.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }
        let matched = Bundle.preferredLocalizations(from: available, forPreferences: [wanted]).first
        // With nothing in common the system falls back to the first or the development language: that isn't a match.
        guard let matched, matched.split(separator: "-").first?.lowercased() == wanted.split(separator: "-").first?.lowercased() else { return nil }
        return matched
    }

    nonisolated(unsafe) private static let bundles = NSCache<NSString, Bundle>()

    /// Where strings for the phone being answered are looked up: that language's folder of the app, or the app itself.
    static var bundle: Bundle {
        guard let name = localization(for: language, available: Bundle.main.localizations) else { return .main }
        if let cached = bundles.object(forKey: name as NSString) { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "lproj"), let found = Bundle(path: path) else { return .main }
        bundles.setObject(found, forKey: name as NSString)
        return found
    }

    /// Runs `work` answering in `language`.
    static func speaking<T>(_ language: String?, _ work: () -> T) -> T {
        $language.withValue(language) { StreamWords.$say.withValue({ stream($0) }, operation: work) }
    }

    static func speakingAsync<T: Sendable>(_ language: String?, _ work: @Sendable () async -> T) async -> T {
        await $language.withValue(language) { await StreamWords.$say.withValue({ stream($0) }, operation: work) }
    }

    /// A stream refusal in the language being answered in.
    static func stream(_ refusal: StreamRefusal) -> String {
        let bundle = bundle
        switch refusal {
        case .notInLibrary:
            return String(localized: "That song isn’t in the Mac’s library.", bundle: bundle, comment: "Stream to phone: the phone asked for a song the Mac no longer has.")
        case .cannotStream:
            return String(localized: "This can’t be streamed.", bundle: bundle, comment: "Stream to phone: a song the Mac can't send to the phone, with no closer reason.")
        case .cannotReadNow:
            return String(localized: "The Mac can’t read this file right now.", bundle: bundle, comment: "Stream to phone: the song's file couldn't be opened (a share that is away, say).")
        case .tooManyChannels(let channels, let most):
            return String(localized: "This has \(channels) channels; Vespertine streams up to \(most). It plays on the Mac.", bundle: bundle, comment: "Stream to phone: a song with more channels than can be sent. Both values are whole numbers, e.g. 12 and 8.")
        case .cannotConvert(let fileExtension):
            return String(localized: "Vespertine on the Mac can’t convert this kind of file (.\(fileExtension)) for the phone. It plays on the Mac.", bundle: bundle, comment: "Stream to phone: %@ is a file extension, e.g. “mid”.")
        case .streamNotOpen:
            return String(localized: "That stream isn’t open.", bundle: bundle, comment: "Stream to phone: the phone read from a stream it had closed. Rarely seen.")
        case .badRange:
            return String(localized: "That range isn’t valid.", bundle: bundle, comment: "Stream to phone: the phone asked for bytes outside the file. Rarely seen.")
        case .readFailed:
            return String(localized: "The Mac couldn’t read the file.", bundle: bundle, comment: "Stream to phone: reading the song's file failed part-way.")
        case .streamingOff:
            return String(localized: "Streaming to phones is off on this Mac. Turn on Stream to Phones in Vespertine › Settings › Remote.", bundle: bundle, comment: "Remote control: a phone asked to play a song itself while the Mac's Stream to Phones switch is off.")
        case .olderPhone:
            return String(localized: "This Mac’s connection with the phone is the older kind, which can’t stream. Update Vespertine on the phone.", bundle: bundle, comment: "Stream to phone: the phone app is too old to play songs itself.")
        }
    }
}
