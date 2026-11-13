//
// Vespertine: a network renderer's device description (UPnP Device Architecture 1.1, section 2.3) and its services'
// descriptions (SCPD, section 2.5): who it is, and which UPnP AV and OpenHome services it offers.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct UPnPService: Sendable, Hashable {
    public var type: String
    public var id: String
    public var controlURL: URL
    public var eventURL: URL?
    public var scpdURL: URL

    public init(type: String, id: String, controlURL: URL, eventURL: URL? = nil, scpdURL: URL) {
        self.type = type
        self.id = id
        self.controlURL = controlURL
        self.eventURL = eventURL
        self.scpdURL = scpdURL
    }
}

/// The services Vespertine uses, in any version.
public enum ServiceKind: String, Sendable, CaseIterable {
    case avTransport = "urn:schemas-upnp-org:service:AVTransport:"
    case renderingControl = "urn:schemas-upnp-org:service:RenderingControl:"
    case connectionManager = "urn:schemas-upnp-org:service:ConnectionManager:"
    case ohProduct = "urn:av-openhome-org:service:Product:"
    case ohPlaylist = "urn:av-openhome-org:service:Playlist:"
    case ohTime = "urn:av-openhome-org:service:Time:"
    case ohInfo = "urn:av-openhome-org:service:Info:"
    case ohVolume = "urn:av-openhome-org:service:Volume:"

    public func matches(_ type: String) -> Bool {
        type.hasPrefix(rawValue) && Int(type.dropFirst(rawValue.count)) != nil
    }

    /// The name shown in the renderer's details.
    public var displayName: String {
        switch self {
        case .avTransport: "AVTransport"
        case .renderingControl: "RenderingControl"
        case .connectionManager: "ConnectionManager"
        case .ohProduct: "Product"
        case .ohPlaylist: "Playlist"
        case .ohTime: "Time"
        case .ohInfo: "Info"
        case .ohVolume: "Volume"
        }
    }
}

public struct DeviceDescription: Sendable, Hashable {
    public var udn: String
    public var friendlyName: String
    public var manufacturer: String
    public var modelName: String
    public var modelNumber: String?
    public var modelDescription: String?
    public var location: URL
    public var services: [UPnPService]

    public init(udn: String, friendlyName: String, manufacturer: String = "", modelName: String = "", modelNumber: String? = nil,
                modelDescription: String? = nil, location: URL, services: [UPnPService]) {
        self.udn = udn
        self.friendlyName = friendlyName
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.modelNumber = modelNumber
        self.modelDescription = modelDescription
        self.location = location
        self.services = services
    }

    public func service(_ kind: ServiceKind) -> UPnPService? { services.first { kind.matches($0.type) } }

    /// Only the services whose control and description URLs are on the description's own host: a description can't send
    /// Vespertine's requests anywhere else on the network.
    public func confined() -> DeviceDescription {
        var copy = self
        let host = location.host?.lowercased()
        copy.services = services.filter { $0.controlURL.host?.lowercased() == host && $0.scpdURL.host?.lowercased() == host }
        return copy
    }

    public enum ParseError: Error { case notADescription }

    /// The renderer in `data`: the first device (the root or an embedded one) that is a MediaRenderer or has an
    /// AVTransport or OpenHome Playlist service, else the root device.
    public static func parse(_ data: Data, location: URL) throws -> DeviceDescription {
        let delegate = DescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.devices.isEmpty else { throw ParseError.notADescription }
        let base = delegate.urlBase.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? location
        let chosen = delegate.devices.first { d in
            d.fields["deviceType"]?.contains(":device:MediaRenderer:") == true
                || d.services.contains { ServiceKind.avTransport.matches($0["serviceType"] ?? "") || ServiceKind.ohPlaylist.matches($0["serviceType"] ?? "") }
        } ?? delegate.devices[0]
        func resolve(_ text: String?) -> URL? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return URL(string: text, relativeTo: base)?.absoluteURL
        }
        let services: [UPnPService] = chosen.services.compactMap { s in
            guard let type = s["serviceType"], let control = resolve(s["controlURL"]), let scpd = resolve(s["SCPDURL"]) else { return nil }
            return UPnPService(type: type, id: s["serviceId"] ?? "", controlURL: control, eventURL: resolve(s["eventSubURL"]), scpdURL: scpd)
        }
        guard let udn = chosen.fields["UDN"], !udn.isEmpty else { throw ParseError.notADescription }
        return DeviceDescription(udn: udn, friendlyName: chosen.fields["friendlyName"] ?? udn,
                                 manufacturer: chosen.fields["manufacturer"] ?? "", modelName: chosen.fields["modelName"] ?? "",
                                 modelNumber: chosen.fields["modelNumber"], modelDescription: chosen.fields["modelDescription"],
                                 location: location, services: services)
    }
}

/// Collects every `<device>` (flattened, embedded ones included) with its own fields and services.
private final class DescriptionParser: NSObject, XMLParserDelegate {
    struct Device { var fields: [String: String] = [:]; var services: [[String: String]] = [] }
    var devices: [Device] = []
    var urlBase: String?
    private var stack: [Device] = []
    private var service: [String: String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "device": stack.append(Device())
        case "service": service = [:]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        switch name {
        case "device":
            if let device = stack.popLast() { devices.append(device) }
        case "service":
            if let service, !stack.isEmpty { stack[stack.count - 1].services.append(service) }
            service = nil
        case "URLBase":
            urlBase = value
        default:
            if service != nil { service?[name] = value }
            else if !stack.isEmpty, stack[stack.count - 1].fields[name] == nil { stack[stack.count - 1].fields[name] = value }
        }
    }
}

/// A service description's action names.
public enum SCPD {
    public static func actions(_ data: Data) throws -> Set<String> {
        let delegate = SCPDParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw DeviceDescription.ParseError.notADescription }
        return delegate.actions
    }
}

private final class SCPDParser: NSObject, XMLParserDelegate {
    var actions: Set<String> = []
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        // <action><name> only, not an argument's <name>.
        if name == "name", path.count >= 2, path[path.count - 2] == "action" {
            actions.insert(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        path.removeLast()
        text = ""
    }
}

/// How Vespertine drives a renderer.
public enum RendererKind: Sendable, Hashable {
    /// OpenHome Product, Playlist, Time and Info: a playlist of the current and next song.
    case openHome
    /// UPnP AV: AVTransport and ConnectionManager. `gapless`: it has SetNextAVTransportURI.
    case av(gapless: Bool)

    /// `avActions`: AVTransport's action names (from its SCPD), nil when not read; without it, AV isn't assumed gapless.
    public static func of(_ d: DeviceDescription, avActions: Set<String>?) -> RendererKind? {
        if d.service(.ohProduct) != nil, d.service(.ohPlaylist) != nil, d.service(.ohTime) != nil, d.service(.ohInfo) != nil {
            return .openHome
        }
        if d.service(.avTransport) != nil, d.service(.connectionManager) != nil {
            return .av(gapless: avActions?.contains("SetNextAVTransportURI") == true)
        }
        return nil
    }

    public var protocolName: String {
        switch self {
        case .openHome: "OpenHome"
        case .av: "UPnP AV"
        }
    }

    public var gapless: Bool {
        switch self {
        case .openHome: true
        case .av(let gapless): gapless
        }
    }
}
