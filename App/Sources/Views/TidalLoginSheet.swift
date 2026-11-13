//
// Vespertine: TIDAL's own login page in a sheet. The redirect that ends it is caught (never loaded) and traded for a session;
// nothing of the page (cookies, storage) is kept.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import VespertineTidal
import WebKit

struct TidalLoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var error: String?
    @State private var finishing = false
    /// Bumped by Try Again: a new login (new verifier) in a fresh page.
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let url, error == nil {
                    TidalLoginWebView(url: url, onRedirect: handle).id(attempt)
                }
                if finishing || (url == nil && error == nil) {
                    ProgressView().controlSize(.small)
                }
                if let error {
                    VStack(spacing: 10) {
                        Text("Couldn’t sign in to TIDAL").font(.headline)
                        Text(verbatim: error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load() } }
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") {
                    model.tidal.cancelLogin()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 640)
        .task { await load() }
    }

    private func load() async {
        error = nil
        finishing = false
        attempt += 1
        url = await model.tidal.beginLogin()
        if url == nil { error = TidalError.missingCredentials.localizedDescription }
    }

    private func handle(_ redirect: TidalLoginRedirect) {
        switch redirect {
        case .ignore:
            break
        case .error(let code):
            // The sheet stays open with the reason; the account is signed out again.
            let message = code == "access_denied"
                ? String(localized: "TIDAL didn’t grant access (access_denied).", comment: "TIDAL login sheet: the user or TIDAL refused the sign-in.")
                : String(localized: "TIDAL answered: \(code)", comment: "TIDAL login sheet: TIDAL's error code, untranslated.")
            model.tidal.cancelLogin(error: message)
            error = message
        case .code(let url):
            finishing = true
            Task {
                do {
                    try await model.tidal.finishLogin(url)
                    dismiss()
                } catch {
                    finishing = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// A `WKWebView` with a non-persistent data store that hands every main-frame navigation to `TidalLoginRedirect.classify`.
struct TidalLoginWebView: NSViewRepresentable {
    let url: URL
    let onRedirect: (TidalLoginRedirect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onRedirect = onRedirect
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onRedirect: (TidalLoginRedirect) -> Void
        init(onRedirect: @escaping (TidalLoginRedirect) -> Void) { self.onRedirect = onRedirect }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }
            let redirect = TidalLoginRedirect.classify(url)
            if redirect == .ignore {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                onRedirect(redirect)
            }
        }
    }
}
