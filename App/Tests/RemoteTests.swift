import Foundation
import Testing
import VespertineLibrary
import VespertineRemoteProtocol
@testable import Vespertine

/// The phone remote's Mac side: what it saves, and the small parsers it relies on. (The TLS and WebSocket transport is
/// tested end to end in Packages/VespertineRemoteKit.)
@MainActor
struct RemoteTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vespertine-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func everythingStartsOff() throws {
        let defaults = UserDefaults(suiteName: "vespertine-remote-test-\(UUID().uuidString)")!
        let store = RemoteStore(dataDirectory: try temporaryFolder(), defaults: defaults)
        #expect(!store.enabled)
        #expect(!store.webEnabled)
        #expect(!store.keepAwake)
        #expect(!store.wakeForNetwork)
        #expect(store.devices.isEmpty)
    }

    @Test func pairingsAndServerIDLastAndStayPrivate() throws {
        let folder = try temporaryFolder()
        let defaults = UserDefaults(suiteName: "vespertine-remote-test-\(UUID().uuidString)")!
        let store = RemoteStore(dataDirectory: folder, defaults: defaults)
        let credential = DeviceCredential.make()
        store.add(PairedRemote(id: credential.device, name: "Alex's iPhone", key: credential.key, pairedAt: .now, lastSeen: nil))

        let again = RemoteStore(dataDirectory: folder, defaults: defaults)
        #expect(again.serverID == store.serverID)
        #expect(again.device(credential.device)?.key == credential.key)
        let file = folder.appendingPathComponent("Remote/paired-remotes.json").path
        let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        again.remove(credential.device)
        #expect(RemoteStore(dataDirectory: folder, defaults: defaults).devices.isEmpty)
        // Another library (a test library) is another server.
        #expect(RemoteStore(dataDirectory: try temporaryFolder(), defaults: defaults).serverID != store.serverID)
    }

    @Test func wakeForNetworkIsReadFromPmset() {
        let output = """
        System-wide power settings:
        Currently in use:
         standby              1
         womp                 1
         networkoversleep     0
        """
        #expect(RemoteWakeForNetwork.parse(output) == true)
        #expect(RemoteWakeForNetwork.parse(output.replacingOccurrences(of: "womp                 1", with: "womp                 0")) == false)
        #expect(RemoteWakeForNetwork.parse("Currently in use:\n sleep 1\n") == nil)
    }

    @Test func coversAreTypedByTheirBytes() {
        #expect(RemoteBridge.mimeType(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(RemoteBridge.mimeType(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) == "image/png")
        #expect(RemoteBridge.mimeType(of: Data("RIFF0000WEBPVP8 ".utf8)) == "image/webp")
        #expect(RemoteBridge.mimeType(of: Data([1, 2, 3])) == "application/octet-stream")
    }

    @Test func artworkKeysCantLeaveTheArtworkFolder() async {
        let store = ArtworkStore(directory: FileManager.default.temporaryDirectory)
        #expect(await RemoteBridge.artwork(key: "../../etc/passwd", size: 600, store: store) == nil)
        #expect(await RemoteBridge.artwork(key: "a/b", size: 600, store: store) == nil)
        #expect(await RemoteBridge.artwork(key: "", size: 600, store: store) == nil)
    }

    @Test func webRequestsParseOnlyWhenComplete() throws {
        let head = "POST /command?x=1 HTTP/1.1\r\nHost: mac.local\r\nContent-Type: application/json\r\nCookie: a=1; vespertine-remote=abc\r\nContent-Length: 11\r\n\r\n"
        #expect(HTTPRequest(Data(head.utf8)) == nil)
        #expect(HTTPRequest(Data((head + "{\"play\":").utf8)) == nil)
        let request = try #require(HTTPRequest(Data((head + "{\"play\":{}}").utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/command")
        #expect(request.query["x"] == "1")
        #expect(request.isJSON)
        #expect(request.cookies["vespertine-remote"] == "abc")
        #expect(String(decoding: request.body, as: UTF8.self) == "{\"play\":{}}")
        #expect(HTTPRequest(Data("GET / HTTP/1.1\r\n\r\n".utf8))?.path == "/")
    }

    @Test func browserTokensCompareWholly() {
        let hash = RemoteWebServer.hash("token")
        #expect(RemoteWebServer.constantTimeEqual(hash, RemoteWebServer.hash("token")))
        #expect(!RemoteWebServer.constantTimeEqual(hash, RemoteWebServer.hash("tokem")))
        #expect(!RemoteWebServer.constantTimeEqual(hash, Data()))
    }

    @Test func theWebPageCarriesItsWordsSafely() {
        let page = RemoteWebPage.html(serverName: "</script><script>alert(1)</script>")
        #expect(!page.contains("</script><script>alert(1)"))
        #expect(page.contains("const L = {"))
        #expect(!page.contains("__STRINGS__"))
    }
}
