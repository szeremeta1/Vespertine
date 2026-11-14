//
// Vespertine: device descriptions, service descriptions and protocol info of network renderers.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import VespertineAudio
@testable import VespertineUPnP

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("Renderer descriptions")
struct DescriptionTests {
    let moodeLocation = URL(string: "http://192.168.1.20:49152/uuid-5f8e/description.xml")!

    @Test("An upmpdcli-style description: identity and every service, URLs resolved against its location")
    func moode() throws {
        let d = try DeviceDescription.parse(fixture("moode-description.xml"), location: moodeLocation)
        #expect(d.udn == "uuid:5f8e1c2a-0000-1111-2222-b827eb000001")
        #expect(d.friendlyName == "moOde UPNP")
        #expect(d.manufacturer == "JF Light")
        #expect(d.modelName == "UpMPD")
        #expect(d.modelNumber == "1.8.12")
        #expect(d.services.count == 8)
        let playlist = try #require(d.service(.ohPlaylist))
        #expect(playlist.controlURL == URL(string: "http://192.168.1.20:49152/ctl/Playlist"))
        #expect(playlist.scpdURL == URL(string: "http://192.168.1.20:49152/upmpd/OHPlaylist.xml"))
        #expect(d.service(.ohProduct)?.type == "urn:av-openhome-org:service:Product:2")
        #expect(d.service(.avTransport) != nil)
        #expect(RendererKind.of(d, avActions: nil) == .openHome)
    }

    @Test("A renderer embedded in a root device, with URLBase and an escaped name")
    func embeddedAV() throws {
        let d = try DeviceDescription.parse(fixture("av-only-description.xml"), location: URL(string: "http://10.0.0.7:8200/desc.xml")!)
        #expect(d.udn == "uuid:renderer-0002")
        #expect(d.friendlyName == "Living Room & Kitchen")
        #expect(d.service(.avTransport)?.controlURL == URL(string: "http://10.0.0.7:8200/base/control/avt"))
        #expect(d.service(.connectionManager)?.eventURL == nil)
        #expect(d.service(.ohPlaylist) == nil)
    }

    @Test("AV gapless comes from SetNextAVTransportURI in the service description")
    func avGapless() throws {
        let d = try DeviceDescription.parse(fixture("av-only-description.xml"), location: URL(string: "http://10.0.0.7:8200/desc.xml")!)
        let with = try SCPD.actions(fixture("avtransport-scpd-with-next.xml"))
        let without = try SCPD.actions(fixture("avtransport-scpd-without-next.xml"))
        #expect(with.contains("SetNextAVTransportURI"))
        #expect(!without.contains("SetNextAVTransportURI"))
        #expect(without.contains("GetPositionInfo"))
        #expect(RendererKind.of(d, avActions: with) == .av(gapless: true))
        #expect(RendererKind.of(d, avActions: without) == .av(gapless: false))
    }

    @Test("Something that isn't XML is an error")
    func notXML() {
        #expect(throws: (any Error).self) { try DeviceDescription.parse(Data("hello".utf8), location: moodeLocation) }
    }

    @Test("Service kinds match any version")
    func serviceVersions() {
        #expect(ServiceKind.ohProduct.matches("urn:av-openhome-org:service:Product:3"))
        #expect(ServiceKind.avTransport.matches("urn:schemas-upnp-org:service:AVTransport:2"))
        #expect(!ServiceKind.ohProduct.matches("urn:av-openhome-org:service:Playlist:1"))
    }
}

@Suite("Renderer capabilities")
struct CapabilityTests {
    static let upmpdcliSink = "http-get:*:audio/flac:*,http-get:*:audio/x-flac:*,http-get:*:audio/wav:*,http-get:*:audio/x-aiff:*,"
        + "http-get:*:audio/mpeg:*,http-get:*:audio/L16;rate=44100;channels=2:*,http-get:*:audio/L16;rate=48000;channels=2:*,"
        + "http-get:*:audio/x-dsd:*,rtsp-rtp-udp:*:audio/L16:*"

    @Test("http-get MIME types are normalised; other protocols are ignored")
    func parses() {
        let caps = RendererCapabilities.parse(sink: Self.upmpdcliSink)
        #expect(caps.accepts(mime: "audio/flac"))
        #expect(caps.accepts(mime: "audio/x-flac"))
        #expect(caps.accepts(mime: "audio/x-wav"))
        #expect(caps.accepts(mime: "audio/aiff"))
        #expect(!caps.accepts(mime: "audio/mp4"))
        #expect(caps.acceptedFormats.contains("FLAC"))
        #expect(caps.acceptedFormats.contains("WAV"))
        #expect(!caps.entries.contains { $0.proto != "http-get" })
    }

    @Test("A stated rate limit is the maximum; none stated is unknown, not assumed")
    func maxFormat() {
        let stated = RendererCapabilities.parse(sink: "http-get:*:audio/L24;rate=96000;channels=2:*,http-get:*:audio/L16;rate=48000;channels=6:*")
        #expect(stated.maxSampleRate == 96000)
        #expect(stated.maxChannels == 6)
        let unstated = RendererCapabilities.parse(sink: "http-get:*:audio/flac:*")
        #expect(unstated.maxSampleRate == nil)
        #expect(unstated.maxChannels == nil)
    }

    @Test("A source beyond what the renderer states for that type, or in a type it doesn't take, is warned about")
    func warnings() {
        let caps = RendererCapabilities.parse(sink: "http-get:*:audio/flac:*,http-get:*:audio/L24;rate=96000;channels=2:*")
        let hiRes = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 192_000, bitDepth: 24, channels: 6)
        let lpcm = caps.warnings(for: hiRes, sending: "audio/L24")
        #expect(lpcm.contains(.rateAboveMaximum(source: 192_000, max: 96000)))
        #expect(lpcm.contains(.channelsAboveMaximum(source: 6, max: 2)))
        // The LPCM limits say nothing about FLAC, which this renderer takes with no limit stated.
        #expect(caps.warnings(for: hiRes, sending: "audio/flac").isEmpty)
        #expect(caps.warnings(for: hiRes, sending: "audio/x-wav").contains(.formatNotAccepted("WAV")))
        let cd = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 44_100, bitDepth: 16, channels: 2)
        #expect(caps.warnings(for: cd, sending: "audio/L24").isEmpty)
        #expect(!lpcm.map(\.message).contains(""))
    }

    @Test("upmpdcli's 44.1/48 kHz L16 entries don't make a 96 kHz FLAC a warning")
    func noFalseLimit() {
        let caps = RendererCapabilities.parse(sink: Self.upmpdcliSink)
        let source = SourceFormat(encoding: .pcm, codec: "FLAC", sampleRate: 96_000, bitDepth: 24, channels: 2)
        #expect(caps.warnings(for: source, sending: "audio/flac").isEmpty)
    }

    @Test("File extensions map to the MIME types renderers announce")
    func mimeTypes() {
        #expect(MediaType.mime(forExtension: "FLAC") == "audio/flac")
        #expect(MediaType.mime(forExtension: "wav") == "audio/wav")
        #expect(MediaType.mime(forExtension: "aif") == "audio/aiff")
        #expect(MediaType.mime(forExtension: "m4a") == "audio/mp4")
        #expect(MediaType.mime(forExtension: "dsf") == "audio/x-dsf")
        #expect(MediaType.mime(forExtension: "xyz") == nil)
    }
}
