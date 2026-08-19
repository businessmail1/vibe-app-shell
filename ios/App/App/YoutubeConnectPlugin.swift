import Foundation
import Capacitor
import UIKit
import WebKit

/**
 One-tap "Connect YouTube" for the native app.

 A web page cannot read another site's cookies — that is the same-origin policy,
 and it is why the browser build has to fall back to a cookie-exporter
 extension. A native app has no such restriction over its OWN webview: we open
 YouTube in a WKWebView backed by the default data store, let the user sign in
 normally, then read the resulting session out of that store and hand it to the
 web layer, which posts it to Vibe.

 Nothing is scraped or automated — the user types their own credentials into
 Google's real sign-in page, exactly as they would in Safari.
 */
@objc(YoutubeConnectPlugin)
public class YoutubeConnectPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "YoutubeConnectPlugin"
    public let jsName = "YoutubeConnect"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise)
    ]

    @objc func connect(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let presenter = self.bridge?.viewController else {
                call.reject("No view controller to present from")
                return
            }
            let signIn = YoutubeSignInViewController()
            signIn.onFinish = { cookies in
                guard let cookies = cookies, !cookies.isEmpty else {
                    call.resolve(["cancelled": true])
                    return
                }
                call.resolve(["cookies": Self.netscapeFormat(cookies)])
            }
            let nav = UINavigationController(rootViewController: signIn)
            nav.modalPresentationStyle = .fullScreen
            presenter.present(nav, animated: true)
        }
    }

    /// yt-dlp reads the classic Netscape cookies.txt layout, tab separated:
    /// domain, includeSubdomains, path, secure, expiry, name, value.
    static func netscapeFormat(_ cookies: [HTTPCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File", "# Exported by Vibe"]
        // A year out is plenty; session cookies carry no expiry of their own.
        let fallbackExpiry = Int(Date().addingTimeInterval(60 * 60 * 24 * 365).timeIntervalSince1970)
        for cookie in cookies {
            let domain = cookie.domain
            let includeSubdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expiry = cookie.expiresDate.map { Int($0.timeIntervalSince1970) } ?? fallbackExpiry
            let fields = [
                domain,
                includeSubdomains,
                cookie.path,
                secure,
                String(expiry),
                cookie.name,
                cookie.value
            ]
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Full-screen YouTube sign-in, with Done/Cancel in the navigation bar.
final class YoutubeSignInViewController: UIViewController, WKNavigationDelegate {
    var onFinish: (([HTTPCookie]?) -> Void)?
    private var webView: WKWebView!
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign in to YouTube"
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        // The DEFAULT store is the one we can read back afterwards.
        config.websiteDataStore = .default()
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        view.addSubview(webView)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Done", style: .done, target: self, action: #selector(doneTapped))

        var request = URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!)
        // Google refuses sign-in from a webview advertising itself as one, so
        // present as mobile Safari.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.load(request)
    }

    /// Once we land back on YouTube itself the sign-in is done — collect and close.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didFinish, let host = webView.url?.host else { return }
        guard host.contains("youtube.com") else { return }
        collectCookies { cookies in
            // Only auto-close once a real session exists, otherwise the signed-out
            // youtube.com landing page would end it immediately.
            let signedIn = cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
            guard signedIn else { return }
            self.finish(with: cookies)
        }
    }

    @objc private func doneTapped() {
        collectCookies { self.finish(with: $0) }
    }

    @objc private func cancelTapped() {
        guard !didFinish else { return }
        didFinish = true
        dismiss(animated: true) { self.onFinish?(nil) }
    }

    private func collectCookies(_ completion: @escaping ([HTTPCookie]) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
            let relevant = all.filter {
                $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
            }
            completion(relevant)
        }
    }

    private func finish(with cookies: [HTTPCookie]) {
        guard !didFinish else { return }
        didFinish = true
        dismiss(animated: true) { self.onFinish?(cookies) }
    }
}
