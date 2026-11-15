//
// Vespertine: what the receiver says it is: the device description control apps read (UPnP Device Architecture 1.1, section
// 2.3) and the descriptions of its three services (AVTransport:1, RenderingControl:1, ConnectionManager:1).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public enum ReceiverService: String, Sendable, CaseIterable {
    case avTransport = "AVTransport"
    case renderingControl = "RenderingControl"
    case connectionManager = "ConnectionManager"

    public var type: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
    public var id: String { "urn:upnp-org:serviceId:\(rawValue)" }
    public var scpdPath: String { "/receiver/scpd/\(rawValue).xml" }
    public var controlPath: String { "/receiver/control/\(rawValue)" }
    public var eventPath: String { "/receiver/event/\(rawValue)" }
}

public enum ReceiverDescription {
    public static let deviceType = "urn:schemas-upnp-org:device:MediaRenderer:1"
    public static let descriptionPath = "/receiver/description.xml"
    /// The longest name a listener may give the receiver (UDA: friendlyName should be under 64 characters).
    public static let maximumNameLength = 63

    /// What this Mac is called on the network: `name`, cut to what a description may carry, never empty.
    public static func friendlyName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }
        return trimmed.isEmpty ? "Vespertine" : String(trimmed.prefix(maximumNameLength))
    }

    /// The types a search may ask for, and the USN each is answered and announced with.
    public static func advertisements(udn: String) -> [(type: String, usn: String)] {
        [("upnp:rootdevice", "\(udn)::upnp:rootdevice"), (udn, udn), (deviceType, "\(udn)::\(deviceType)")]
            + ReceiverService.allCases.map { ($0.type, "\(udn)::\($0.type)") }
    }

    public static func device(udn: String, name: String, version: String) -> String {
        let services = ReceiverService.allCases.map {
            "<service><serviceType>\($0.type)</serviceType><serviceId>\($0.id)</serviceId><SCPDURL>\($0.scpdPath)</SCPDURL>"
                + "<controlURL>\($0.controlPath)</controlURL><eventSubURL>\($0.eventPath)</eventSubURL></service>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\">"
            + "<specVersion><major>1</major><minor>0</minor></specVersion><device>"
            + "<deviceType>\(deviceType)</deviceType><friendlyName>\(SOAP.escape(friendlyName(name)))</friendlyName>"
            + "<manufacturer>Vespertine</manufacturer><manufacturerURL>https://vespertineapp.com</manufacturerURL>"
            + "<modelDescription>Vespertine for macOS, as a network player</modelDescription><modelName>Vespertine</modelName>"
            + "<modelNumber>\(SOAP.escape(version))</modelNumber><modelURL>https://vespertineapp.com</modelURL>"
            + "<UDN>\(SOAP.escape(udn))</UDN><serviceList>\(services)</serviceList></device></root>"
    }

    // MARK: Service descriptions

    private struct Variable {
        var name: String
        var type = "string"
        var evented = false
        var allowed: [String] = []
        var range: (Int, Int)?
    }

    private static func scpd(actions: [(String, [(name: String, out: Bool, related: String)])], variables: [Variable]) -> String {
        let actionList = actions.map { action, arguments in
            let list = arguments.map {
                "<argument><name>\($0.name)</name><direction>\($0.out ? "out" : "in")</direction><relatedStateVariable>\($0.related)</relatedStateVariable></argument>"
            }.joined()
            return "<action><name>\(action)</name>" + (list.isEmpty ? "" : "<argumentList>\(list)</argumentList>") + "</action>"
        }.joined()
        let table = variables.map { v in
            var xml = "<stateVariable sendEvents=\"\(v.evented ? "yes" : "no")\"><name>\(v.name)</name><dataType>\(v.type)</dataType>"
            if !v.allowed.isEmpty { xml += "<allowedValueList>" + v.allowed.map { "<allowedValue>\($0)</allowedValue>" }.joined() + "</allowedValueList>" }
            if let range = v.range { xml += "<allowedValueRange><minimum>\(range.0)</minimum><maximum>\(range.1)</maximum><step>1</step></allowedValueRange>" }
            return xml + "</stateVariable>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\">"
            + "<specVersion><major>1</major><minor>0</minor></specVersion><actionList>\(actionList)</actionList>"
            + "<serviceStateTable>\(table)</serviceStateTable></scpd>"
    }

    private static func i(_ name: String, _ related: String) -> (name: String, out: Bool, related: String) { (name, false, related) }
    private static func o(_ name: String, _ related: String) -> (name: String, out: Bool, related: String) { (name, true, related) }

    public static func scpd(_ service: ReceiverService) -> String {
        switch service {
        case .avTransport: avTransport
        case .renderingControl: renderingControl
        case .connectionManager: connectionManager
        }
    }

    public static let transportStates = ["STOPPED", "PLAYING", "PAUSED_PLAYBACK", "TRANSITIONING", "NO_MEDIA_PRESENT"]

    private static let avTransport: String = {
        let instance = i("InstanceID", "A_ARG_TYPE_InstanceID")
        return scpd(actions: [
            ("SetAVTransportURI", [instance, i("CurrentURI", "AVTransportURI"), i("CurrentURIMetaData", "AVTransportURIMetaData")]),
            ("SetNextAVTransportURI", [instance, i("NextURI", "NextAVTransportURI"), i("NextURIMetaData", "NextAVTransportURIMetaData")]),
            ("GetMediaInfo", [instance, o("NrTracks", "NumberOfTracks"), o("MediaDuration", "CurrentMediaDuration"), o("CurrentURI", "AVTransportURI"),
                              o("CurrentURIMetaData", "AVTransportURIMetaData"), o("NextURI", "NextAVTransportURI"),
                              o("NextURIMetaData", "NextAVTransportURIMetaData"), o("PlayMedium", "PlaybackStorageMedium"),
                              o("RecordMedium", "RecordStorageMedium"), o("WriteStatus", "RecordMediumWriteStatus")]),
            ("GetTransportInfo", [instance, o("CurrentTransportState", "TransportState"), o("CurrentTransportStatus", "TransportStatus"),
                                  o("CurrentSpeed", "TransportPlaySpeed")]),
            ("GetPositionInfo", [instance, o("Track", "CurrentTrack"), o("TrackDuration", "CurrentTrackDuration"), o("TrackMetaData", "CurrentTrackMetaData"),
                                 o("TrackURI", "CurrentTrackURI"), o("RelTime", "RelativeTimePosition"), o("AbsTime", "AbsoluteTimePosition"),
                                 o("RelCount", "RelativeCounterPosition"), o("AbsCount", "AbsoluteCounterPosition")]),
            ("GetDeviceCapabilities", [instance, o("PlayMedia", "PossiblePlaybackStorageMedia"), o("RecMedia", "PossibleRecordStorageMedia"),
                                       o("RecQualityModes", "PossibleRecordQualityModes")]),
            ("GetTransportSettings", [instance, o("PlayMode", "CurrentPlayMode"), o("RecQualityMode", "CurrentRecordQualityMode")]),
            ("GetCurrentTransportActions", [instance, o("Actions", "CurrentTransportActions")]),
            ("Stop", [instance]),
            ("Play", [instance, i("Speed", "TransportPlaySpeed")]),
            ("Pause", [instance]),
            ("Seek", [instance, i("Unit", "A_ARG_TYPE_SeekMode"), i("Target", "A_ARG_TYPE_SeekTarget")]),
            ("Next", [instance]),
            ("Previous", [instance]),
        ], variables: [
            Variable(name: "TransportState", allowed: transportStates),
            Variable(name: "TransportStatus", allowed: ["OK", "ERROR_OCCURRED"]),
            Variable(name: "PlaybackStorageMedium", allowed: ["NETWORK", "NONE"]),
            Variable(name: "RecordStorageMedium", allowed: ["NOT_IMPLEMENTED"]),
            Variable(name: "PossiblePlaybackStorageMedia"), Variable(name: "PossibleRecordStorageMedia"),
            Variable(name: "CurrentPlayMode", allowed: ["NORMAL"]),
            Variable(name: "TransportPlaySpeed", allowed: ["1"]),
            Variable(name: "RecordMediumWriteStatus", allowed: ["NOT_IMPLEMENTED"]),
            Variable(name: "CurrentRecordQualityMode", allowed: ["NOT_IMPLEMENTED"]),
            Variable(name: "PossibleRecordQualityModes"),
            Variable(name: "NumberOfTracks", type: "ui4", range: (0, 1)),
            Variable(name: "CurrentTrack", type: "ui4", range: (0, 1)),
            Variable(name: "CurrentTrackDuration"), Variable(name: "CurrentMediaDuration"), Variable(name: "CurrentTrackMetaData"),
            Variable(name: "CurrentTrackURI"), Variable(name: "AVTransportURI"), Variable(name: "AVTransportURIMetaData"),
            Variable(name: "NextAVTransportURI"), Variable(name: "NextAVTransportURIMetaData"),
            Variable(name: "RelativeTimePosition"), Variable(name: "AbsoluteTimePosition"),
            Variable(name: "RelativeCounterPosition", type: "i4"), Variable(name: "AbsoluteCounterPosition", type: "i4"),
            Variable(name: "CurrentTransportActions"),
            Variable(name: "LastChange", evented: true),
            Variable(name: "A_ARG_TYPE_SeekMode", allowed: ["REL_TIME", "ABS_TIME", "TRACK_NR"]),
            Variable(name: "A_ARG_TYPE_SeekTarget"),
            Variable(name: "A_ARG_TYPE_InstanceID", type: "ui4"),
        ])
    }()

    private static let renderingControl: String = {
        let instance = i("InstanceID", "A_ARG_TYPE_InstanceID")
        let channel = i("Channel", "A_ARG_TYPE_Channel")
        return scpd(actions: [
            ("ListPresets", [instance, o("CurrentPresetNameList", "PresetNameList")]),
            ("SelectPreset", [instance, i("PresetName", "A_ARG_TYPE_PresetName")]),
            ("GetVolume", [instance, channel, o("CurrentVolume", "Volume")]),
            ("SetVolume", [instance, channel, i("DesiredVolume", "Volume")]),
            ("GetMute", [instance, channel, o("CurrentMute", "Mute")]),
            ("SetMute", [instance, channel, i("DesiredMute", "Mute")]),
        ], variables: [
            Variable(name: "PresetNameList"),
            Variable(name: "LastChange", evented: true),
            Variable(name: "Volume", type: "ui2", range: (0, 100)),
            Variable(name: "Mute", type: "boolean"),
            Variable(name: "A_ARG_TYPE_Channel", allowed: ["Master"]),
            Variable(name: "A_ARG_TYPE_InstanceID", type: "ui4"),
            Variable(name: "A_ARG_TYPE_PresetName", allowed: ["FactoryDefaults"]),
        ])
    }()

    private static let connectionManager: String = {
        scpd(actions: [
            ("GetProtocolInfo", [o("Source", "SourceProtocolInfo"), o("Sink", "SinkProtocolInfo")]),
            ("GetCurrentConnectionIDs", [o("ConnectionIDs", "CurrentConnectionIDs")]),
            ("GetCurrentConnectionInfo", [i("ConnectionID", "A_ARG_TYPE_ConnectionID"), o("RcsID", "A_ARG_TYPE_RcsID"),
                                          o("AVTransportID", "A_ARG_TYPE_AVTransportID"), o("ProtocolInfo", "A_ARG_TYPE_ProtocolInfo"),
                                          o("PeerConnectionManager", "A_ARG_TYPE_ConnectionManager"), o("PeerConnectionID", "A_ARG_TYPE_ConnectionID"),
                                          o("Direction", "A_ARG_TYPE_Direction"), o("Status", "A_ARG_TYPE_ConnectionStatus")]),
        ], variables: [
            Variable(name: "SourceProtocolInfo", evented: true), Variable(name: "SinkProtocolInfo", evented: true),
            Variable(name: "CurrentConnectionIDs", evented: true),
            Variable(name: "A_ARG_TYPE_ConnectionStatus", allowed: ["OK", "Unknown"]),
            Variable(name: "A_ARG_TYPE_ConnectionManager"),
            Variable(name: "A_ARG_TYPE_Direction", allowed: ["Input", "Output"]),
            Variable(name: "A_ARG_TYPE_ProtocolInfo"),
            Variable(name: "A_ARG_TYPE_ConnectionID", type: "i4"),
            Variable(name: "A_ARG_TYPE_AVTransportID", type: "i4"),
            Variable(name: "A_ARG_TYPE_RcsID", type: "i4"),
        ])
    }()

    // MARK: What the engine decodes

    /// The media types the receiver takes, each with the spellings control apps use. Every one is a container Vespertine's
    /// engine opens (see `StreamSniffer`): nothing is listed that would be refused when it arrives.
    public static let sinkMediaTypes: [String] = [
        "audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav", "audio/wave", "audio/aiff", "audio/x-aiff",
        "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/aacp", "audio/mpeg", "audio/mp3",
        "audio/x-dsf", "audio/dsf", "audio/x-dsd", "audio/x-dff", "audio/dff", "audio/ogg", "application/ogg", "audio/opus",
        "audio/x-ape", "audio/x-wavpack", "audio/x-matroska",
    ]

    public static var sinkProtocolInfo: String { sinkMediaTypes.map { "http-get:*:\($0):*" }.joined(separator: ",") }

    /// The file extension the decoders go by for a media type a control app named, when the bytes themselves don't say.
    public static func fileExtension(forMediaType type: String?) -> String? {
        guard let type = type?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch type {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/aac", "audio/aacp": return "aac"
        case "audio/mpeg", "audio/mp3", "audio/x-mpeg": return "mp3"
        case "audio/x-dsf", "audio/dsf", "audio/x-dsd": return "dsf"
        case "audio/x-dff", "audio/dff": return "dff"
        case "audio/ogg", "application/ogg", "audio/x-ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/x-ape", "audio/ape": return "ape"
        case "audio/x-wavpack", "audio/wavpack": return "wv"
        case "audio/x-matroska": return "mka"
        default: return nil
        }
    }
}
