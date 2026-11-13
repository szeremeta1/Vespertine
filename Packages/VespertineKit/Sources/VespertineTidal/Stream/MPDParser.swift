//
// Vespertine: reads the DASH manifest (MPD) TIDAL sends for hi-res tracks: the codec, the sample rate, and the initialization and
// media segment URLs of its first audio representation.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct MPDInfo: Equatable {
    var codecs: String
    var sampleRate: Int?
    /// The `SegmentTemplate` URLs, as written (`media` still holds `$Number$`).
    var initialization: String
    var media: String
    var startNumber: Int
    /// Σ over `<S>` of (`r` + 1), `r` defaulting to 0 (ISO/IEC 23009-1).
    var segmentCount: Int
    var hasContentProtection: Bool
}

enum MPDParser {
    static func parse(_ xml: String) throws -> MPDInfo {
        let collector = Collector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        guard parser.parse(), collector.failure == nil else {
            throw TidalError.malformedStream(collector.failure ?? "the manifest is not valid XML: \(parser.parserError?.localizedDescription ?? "unknown")")
        }
        guard let representation = collector.firstRepresentation else { throw TidalError.malformedStream("the manifest has no audio representation") }
        // DASH allows the template on the Representation or on its AdaptationSet.
        guard let template = representation.template ?? collector.firstAdaptationTemplate else {
            throw TidalError.malformedStream("the manifest has no SegmentTemplate")
        }
        guard let initialization = template.attributes["initialization"], let media = template.attributes["media"] else {
            throw TidalError.malformedStream("the SegmentTemplate has no initialization or media URL")
        }
        if let invalid = template.invalidRepeat {
            throw TidalError.malformedStream("unsupported segment repeat r=\(invalid)")
        }
        guard !template.segments.isEmpty else { throw TidalError.malformedStream("the SegmentTemplate has no SegmentTimeline") }
        return MPDInfo(codecs: representation.attributes["codecs"] ?? collector.firstAdaptationCodecs ?? "",
                       sampleRate: (representation.attributes["audioSamplingRate"] ?? collector.firstAdaptationSampleRate).flatMap { Int($0) },
                       initialization: initialization, media: media,
                       startNumber: template.attributes["startNumber"].flatMap { Int($0) } ?? 1,
                       segmentCount: template.segments.reduce(0) { $0 + $1 + 1 },
                       hasContentProtection: collector.sawContentProtection)
    }

    private struct Template {
        var attributes: [String: String]
        /// The `r` of each `<S>`.
        var segments: [Int] = []
        var invalidRepeat: Int?
    }

    private struct Representation {
        var attributes: [String: String]
        var template: Template?
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var failure: String?
        var sawContentProtection = false
        var firstRepresentation: Representation?
        var firstAdaptationTemplate: Template?
        var firstAdaptationCodecs: String?
        var firstAdaptationSampleRate: String?

        private var adaptationSets = 0
        private var inFirstAdaptationSet = false
        private var representations = 0
        private var inFirstRepresentation = false
        private var currentTemplate: Template?
        private var templateBelongsToRepresentation = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "ContentProtection":
                sawContentProtection = true
            case "AdaptationSet":
                adaptationSets += 1
                inFirstAdaptationSet = adaptationSets == 1
                representations = 0
                if inFirstAdaptationSet {
                    firstAdaptationCodecs = attributes["codecs"]
                    firstAdaptationSampleRate = attributes["audioSamplingRate"]
                }
            case "Representation":
                representations += 1
                inFirstRepresentation = inFirstAdaptationSet && representations == 1
                if inFirstRepresentation { firstRepresentation = Representation(attributes: attributes) }
            case "SegmentTemplate":
                if inFirstRepresentation {
                    currentTemplate = Template(attributes: attributes)
                    templateBelongsToRepresentation = true
                } else if inFirstAdaptationSet && representations == 0 {
                    currentTemplate = Template(attributes: attributes)
                    templateBelongsToRepresentation = false
                }
            case "S":
                guard currentTemplate != nil else { return }
                let repeats = attributes["r"].flatMap { Int($0) } ?? 0
                if repeats < 0 { currentTemplate?.invalidRepeat = repeats } else { currentTemplate?.segments.append(repeats) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "SegmentTemplate":
                guard let template = currentTemplate else { return }
                if templateBelongsToRepresentation { firstRepresentation?.template = template } else { firstAdaptationTemplate = template }
                currentTemplate = nil
            case "Representation":
                inFirstRepresentation = false
            case "AdaptationSet":
                inFirstAdaptationSet = false
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            failure = "the manifest is not valid XML: \(parseError.localizedDescription)"
        }
    }
}
