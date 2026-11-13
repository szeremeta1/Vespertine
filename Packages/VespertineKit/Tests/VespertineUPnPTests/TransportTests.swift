//
// Vespertine: OpenHome and UPnP AV control against the fake renderer; SOAP envelopes, faults and DIDL-Lite.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineUPnP

@Suite("SOAP and DIDL-Lite")
struct SOAPTests {
    @Test("An envelope names the action in its namespace, with escaped arguments in order")
    func envelope() {
        let text = String(decoding: SOAP.envelope(serviceType: "urn:av-openhome-org:service:Playlist:1", action: "Insert",
                                                  arguments: [("AfterId", "0"), ("Uri", "http://h/a?b=1&c=2"), ("Metadata", "<DIDL-Lite/>")]), as: UTF8.self)
        #expect(text.contains("<u:Insert xmlns:u=\"urn:av-openhome-org:service:Playlist:1\"><AfterId>0</AfterId><Uri>http://h/a?b=1&amp;c=2</Uri><Metadata>&lt;DIDL-Lite/&gt;</Metadata></u:Insert>"))
    }

    @Test("A response's arguments and a fault's code are read")
    func responses() throws {
        let ok = SOAP.response(serviceType: "urn:x", action: "Id", arguments: [("Value", "7")])
        #expect(try SOAP.parseResponse(ok, action: "Id") == ["Value": "7"])
        #expect(throws: UPnPError.badResponse) { try SOAP.parseResponse(ok, action: "Other") }
        #expect(SOAP.parseFault(SOAP.fault(code: 714, description: "Illegal MIME-type")) == .fault(code: 714, description: "Illegal MIME-type"))
    }

    @Test("DIDL-Lite carries the song, escaped, with its format")
    func didl() {
        let didl = DIDLLite.item(id: "1", info: RendererTrackInfo(title: "Rock & Roll <Live>", artist: "A \"B\"", album: "C", duration: 201.5),
                                 url: URL(string: "http://10.0.0.2:5000/media/ab.flac")!, mime: "audio/flac", size: 1234,
                                 format: .init(encoding: .pcm, codec: "FLAC", sampleRate: 192_000, bitDepth: 24, channels: 2))
        #expect(didl.contains("<dc:title>Rock &amp; Roll &lt;Live&gt;</dc:title>"))
        #expect(didl.contains("<upnp:artist>A &quot;B&quot;</upnp:artist>"))
        #expect(didl.contains("protocolInfo=\"http-get:*:audio/flac:*\""))
        #expect(didl.contains("duration=\"0:03:21.500\""))
        #expect(didl.contains("sampleFrequency=\"192000\""))
        #expect(didl.contains("bitsPerSample=\"24\""))
        #expect(didl.contains("object.item.audioItem.musicTrack"))
    }

    @Test("Times in UPnP's format")
    func times() {
        #expect(DIDLLite.time(3725.25) == "1:02:05.250")
        #expect(DIDLLite.seconds("1:02:05.250") == 3725.25)
        #expect(DIDLLite.seconds("0:00:07") == 7)
        #expect(DIDLLite.seconds("NOT_IMPLEMENTED") == nil)
    }
}

func track(_ name: String) -> RendererTrack {
    RendererTrack(uri: URL(string: "http://127.0.0.1:9/media/\(name).flac")!, metadata: "<DIDL-Lite/>")
}

@Suite("Renderer transports", .serialized)
struct TransportTests {
    @Test("OpenHome: the Playlist source is chosen, the playlist replaced by current + next, current started")
    func openHomeLoad() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        defer { fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        #expect(device.kind == .openHome)
        let transport = try OpenHomeTransport(description: device.description)
        let start = fake.calls.count
        try await transport.load(current: track("a"), next: track("b"))
        #expect(fake.selectedSource == 1)   // Playlist is source 1 of Radio, Playlist, Receiver
        #expect(fake.playlistURIs == [track("a").uri.absoluteString, track("b").uri.absoluteString])
        #expect(fake.actions.dropFirst(start) == ["SourceXml", "SourceIndex", "SetSourceIndex", "DeleteAll", "Insert", "Insert", "SeekId", "Play"])
        var status = try await transport.status()
        #expect(status.state == .playing)
        #expect(status.currentURI == track("a").uri)
        fake.setPosition(42)
        fake.advance()
        status = try await transport.status()
        #expect(status.currentURI == track("b").uri)
        #expect(status.position == 42 || status.position == 0)
        try await transport.replaceNext(track("c"))
        #expect(fake.playlistURIs == [track("b").uri.absoluteString, track("c").uri.absoluteString])
    }

    @Test("OpenHome: a reorder replaces only the next entry; pause, seek and stop are passed on")
    func openHomeEdits() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        defer { fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        let transport = try OpenHomeTransport(description: device.description)
        try await transport.load(current: track("a"), next: track("b"))
        try await transport.replaceNext(track("z"))
        #expect(fake.playlistURIs == [track("a").uri.absoluteString, track("z").uri.absoluteString])
        try await transport.replaceNext(nil)
        #expect(fake.playlistURIs == [track("a").uri.absoluteString])
        try await transport.pause()
        #expect(try await transport.status().state == .paused)
        try await transport.seek(to: 61.4)
        #expect(fake.calls.last { $0.action == "SeekSecondAbsolute" }?.arguments["Value"] == "61")
        try await transport.stop()
        #expect(try await transport.status().state == .stopped)
    }

    @Test("AV with SetNextAVTransportURI: gapless, the renderer moves on by itself")
    func avGapless() async throws {
        let fake = try await FakeRenderer(kind: .av(setNext: true))
        defer { fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        #expect(device.kind == .av(gapless: true))
        let transport = try AVTransportControl(description: device.description, gapless: true)
        let start = fake.calls.count
        try await transport.load(current: track("a"), next: track("b"))
        #expect(fake.actions.dropFirst(start) == ["SetAVTransportURI", "SetNextAVTransportURI", "Play"])
        #expect(fake.calls[start].arguments["InstanceID"] == "0")
        #expect(try await transport.status().currentURI == track("a").uri)
        fake.advance()
        #expect(try await transport.status().currentURI == track("b").uri)
        try await transport.replaceNext(track("c"))
        #expect(fake.nextURI == track("c").uri.absoluteString)
        try await transport.seek(to: 75)
        #expect(fake.calls.last?.arguments["Target"] == "0:01:15")
        #expect(fake.calls.last?.arguments["Unit"] == "REL_TIME")
    }

    @Test("AV without SetNext: not gapless; when a song ends, the next one is set and started")
    func avNoSetNext() async throws {
        let fake = try await FakeRenderer(kind: .av(setNext: false))
        defer { fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        #expect(device.kind == .av(gapless: false))
        let transport = try AVTransportControl(description: device.description, gapless: false)
        try await transport.load(current: track("a"), next: track("b"))
        #expect(!fake.actions.contains("SetNextAVTransportURI"))
        _ = try await transport.status()
        fake.advance()   // stops: nothing next on the renderer
        let status = try await transport.status()
        #expect(status.currentURI == track("b").uri)
        #expect(fake.currentURI == track("b").uri.absoluteString)
        #expect(fake.transportState == "Playing")
    }

    @Test("A renderer's refusal comes back as its UPnP error")
    func fault() async throws {
        let fake = try await FakeRenderer(kind: .av(setNext: true))
        defer { fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        let transport = try AVTransportControl(description: device.description, gapless: true)
        fake.fail("SetAVTransportURI", code: 714)
        await #expect(throws: UPnPError.fault(code: 714, description: "Fake failure")) {
            try await transport.load(current: track("a"), next: nil)
        }
    }

    @Test("A renderer's description, kind and capabilities are read in one go")
    func deviceLoad() async throws {
        let fake = try await FakeRenderer(kind: .openHome)
        defer { fake.stop() }
        let device = try await RendererDevice.load(location: fake.location)
        #expect(device.description.friendlyName == "Fake Renderer")
        #expect(device.capabilities.accepts(mime: "audio/flac"))
        #expect(device.uid == "upnp:uuid:fake-\(fake.port)")
        #expect(device.host == "127.0.0.1")
    }
}
