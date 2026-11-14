import Foundation
import ImageIO
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

    @Test func streamingToPhonesStartsOffAndEachPhoneCanBeKeptFromIt() throws {
        let folder = try temporaryFolder()
        let defaults = UserDefaults(suiteName: "vespertine-remote-test-\(UUID().uuidString)")!
        let store = RemoteStore(dataDirectory: folder, defaults: defaults)
        #expect(!store.streamEnabled)
        #expect(store.streamCacheGigabytes == 8)
        let phone = DeviceCredential.make(), tablet = DeviceCredential.make()
        store.add(PairedRemote(id: phone.device, name: "iPhone", key: phone.key, pairedAt: .now, lastSeen: nil))
        store.add(PairedRemote(id: tablet.device, name: "iPad", key: tablet.key, pairedAt: .now, lastSeen: nil))
        // With the switch off nobody streams; with it on, every paired phone may until it is told otherwise.
        #expect(!store.mayStream(phone.device))
        store.streamEnabled = true
        #expect(store.mayStream(phone.device) && store.mayStream(tablet.device))
        store.setMayStream(tablet.device, false)
        store.streamCacheGigabytes = 32
        let again = RemoteStore(dataDirectory: folder, defaults: defaults)
        #expect(again.streamEnabled && again.streamCacheGigabytes == 32)
        #expect(again.mayStream(phone.device) && !again.mayStream(tablet.device))
        // A phone that isn't paired, and a web browser, never stream.
        #expect(!again.mayStream("nobody"))
        let browser = DeviceCredential.make()
        again.add(PairedRemote(id: browser.device, name: "Safari", key: browser.key, pairedAt: .now, lastSeen: nil, web: true))
        #expect(!again.mayStream(browser.device))
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

    @Test func theWebPageIsOneWholePage() {
        // The markup, the style and the script travel in the app's resources and go out as one page.
        let page = RemoteWebPage.html(serverName: "Studio")
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("id=\"view-now\"") && page.contains("id=\"view-queue\"") && page.contains("id=\"pairing\""))
        #expect(page.contains("--brass: #C8A66A"))
        #expect(page.contains("function renderPlayer()"))
        for placeholder in ["__STYLE__", "__SCRIPT__", "__LANG__", "__DIR__", "__SPACED__"] { #expect(!page.contains(placeholder)) }
        #expect(page.contains("<link rel=\"manifest\" href=\"/manifest.webmanifest\">"))
        // Nothing is fetched from anywhere but this Mac.
        #expect(!page.contains("https://") && !page.contains("//cdn"))
    }

    @Test func everyWordThePageUsesIsThere() throws {
        // The script reads its words as L.name: each one must be among those the Mac sends.
        let page = RemoteWebPage.html(serverName: "Studio")
        let known = Set(RemoteWebPage.strings.keys).union(["mac", "plurals"])
        var used = Set<String>()
        for match in page.matches(of: /\bL\.([A-Za-z]+)\b/) { used.insert(String(match.1)) }
        for match in page.matches(of: /data-t="([A-Za-z]+)"/) { used.insert(String(match.1)) }
        #expect(used.count > 40)
        #expect(used.subtracting(known).isEmpty, "missing: \(used.subtracting(known).sorted())")
        #expect(RemoteWebPage.strings.values.allSatisfy { !$0.isEmpty })
    }

    @Test func countsComeInEveryPluralForm() {
        let plurals = RemoteWebPage.plurals
        for kind in ["songs", "albums"] {
            let forms = plurals[kind] ?? [:]
            #expect(Set(forms.keys) == Set(RemoteWebPage.pluralSamples.map(String.init)))
            #expect(forms.values.allSatisfy { !$0.isEmpty && !$0.contains("%") })
        }
    }

    @Test func theManifestMakesItAHomeScreenApp() throws {
        let manifest = try #require(try JSONSerialization.jsonObject(with: RemoteWebPage.manifest()) as? [String: Any])
        #expect(manifest["display"] as? String == "standalone")
        #expect(manifest["start_url"] as? String == "/")
        #expect(manifest["short_name"] as? String == "Vespertine")
        let icons = try #require(manifest["icons"] as? [[String: String]])
        #expect(icons.contains { $0["sizes"] == "192x192" } && icons.contains { $0["sizes"] == "512x512" } && icons.contains { $0["purpose"] == "maskable" })
        // Every icon the manifest and the page name is one the server draws.
        for icon in icons { #expect(RemoteWebIcon.sizes[icon["src"] ?? ""] != nil) }
        #expect(RemoteWebIcon.sizes["/apple-touch-icon.png"] == 180)
    }

    @Test func iconsAreDrawnAtTheirSizes() throws {
        for (path, size) in RemoteWebIcon.sizes {
            let data = try #require(RemoteWebIcon.png(path: path))
            #expect(RemoteBridge.mimeType(of: data) == "image/png")
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == size && image.height == size)
        }
        #expect(RemoteWebIcon.png(path: "/icon-9999.png") == nil)
        #expect(RemoteWebIcon.png(path: "/../etc/passwd") == nil)
        #expect(RemoteWebIcon.png(size: 0, maskable: false) == nil)
        #expect(RemoteWebIcon.svg.hasPrefix("<svg") && !RemoteWebIcon.svg.contains("<script"))
    }

    @Test func nothingIsCachedUnlessItSaysSo() {
        let plain = RemoteWebServer.head(status: 200, type: "application/json", length: 2)
        #expect(plain.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(plain.contains("Cache-Control: no-store\r\n"))
        #expect(plain.contains("X-Content-Type-Options: nosniff\r\n") && plain.contains("X-Frame-Options: DENY\r\n") && plain.contains("Referrer-Policy: no-referrer\r\n"))
        #expect(plain.hasSuffix("\r\n\r\n"))
        // A cover keeps for a day in the browser that asked (it sat behind the cookie); it used to be fetched every time.
        let cover = RemoteWebServer.head(status: 200, type: "image/jpeg", length: 9, headers: ["Cache-Control": "private, max-age=86400"])
        #expect(cover.contains("Cache-Control: private, max-age=86400\r\n") && !cover.contains("no-store"))
        #expect(cover.components(separatedBy: "Cache-Control").count == 2)
        let page = RemoteWebServer.head(status: 200, type: "text/html; charset=utf-8", length: 1, headers: ["Content-Security-Policy": RemoteWebPage.contentSecurityPolicy])
        #expect(page.contains("Content-Security-Policy: default-src 'none';"))
        #expect(page.contains("frame-ancestors 'none'") && page.contains("connect-src 'self'"))
        #expect(RemoteWebServer.head(status: 401, type: "text/plain", length: 0).hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    }

    // MARK: Polish: names and labels on the web remote

    @Test func aPairedBrowserIsNamedFromItsUserAgent() {
        func name(_ ua: String) -> String? { RemoteBrowserName.name(userAgent: ua) }
        #expect(name("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36") == "Chrome on Mac")
        #expect(name("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15") == "Safari on Mac")
        #expect(name("Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1") == "Safari on iPhone")
        #expect(name("Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/130.0.0.0 Mobile/15E148 Safari/604.1") == "Chrome on iPhone")
        #expect(name("Mozilla/5.0 (iPad; CPU OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1") == "Safari on iPad")
        // iPad Safari in desktop mode: a Macintosh user agent, told apart only by its touch screen.
        let macSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
        #expect(RemoteBrowserName.name(userAgent: macSafari, maxTouchPoints: 5) == "Safari on iPad")
        #expect(RemoteBrowserName.name(userAgent: macSafari, maxTouchPoints: 0) == "Safari on Mac")
        #expect(RemoteBrowserName.name(userAgent: macSafari, maxTouchPoints: 1) == "Safari on Mac")
        #expect(RemoteBrowserName.name(userAgent: macSafari) == "Safari on Mac")
        #expect(name("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0") == "Edge on Windows")
        #expect(name("Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0") == "Firefox on Linux")
        #expect(name("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36") == "Chrome on Android")
    }

    @Test func aUserAgentWeCannotReadGivesNoName() {
        #expect(RemoteBrowserName.name(userAgent: "") == nil)
        #expect(RemoteBrowserName.name(userAgent: "curl/8.7.1") == nil)
    }

    @Test func theWebPageNamesPauseAndPositionForScreenReaders() {
        let page = RemoteWebPage.html(serverName: "Mac")
        // Play/Pause says what a press does; the slider is a position, not "Now Playing".
        #expect(page.contains("playing ? L.pause : L.play"))
        #expect(page.contains("$(\"position\").setAttribute(\"aria-label\", L.position)"))
        #expect(!page.contains("$(\"position\").setAttribute(\"aria-label\", L.nowPlaying)"))
        #expect(page.contains("$(\"prev\").setAttribute(\"aria-label\", L.previous)"))
        #expect(page.contains("$(\"volDown\").setAttribute(\"aria-label\", L.volumeDown)"))
        #expect(RemoteWebPage.strings["pause"] != nil)
    }
}
