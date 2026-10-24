import UIKit
import WebKit
#if SWIFT_PACKAGE
// SwiftPM: JoryioUI is its own module. CocoaPods: Joryio/UI is a subspec
// compiled INTO the Joryio module, where this import is a warning that
// fails `pod lib lint` (and so `pod trunk push`).
import Joryio
#endif

/**
 Renders an in-app campaign's HTML in a WKWebView.

 REPLACES six view classes - Modal, Banner, SlideUp, FullScreen, Card, Custom -
 that between them were ~1,100 lines laying out `title`, `body`, `imageUrl` and
 `buttons` with UIKit. None of it could ever run: the server does not send a
 structured message and never has. It sends `template { html, css }`, because
 the campaign editor is HTML-based.

 The six classes differed only in PLACEMENT, which is a handful of constraints -
 so placement is all this keeps. Content is one WebView.

 Mirrors `packages/sdk-web/src/core/inapp.ts` deliberately: same bridge method
 names, same per-type sizing, same URL safety rule. A template authored once
 then behaves the same on web, Android and iOS, which is the entire point of
 the editor producing one document.
 */
final class InAppWebMessageView: BaseMessageView {
    /// Bridge name. Must match the web SDK and Android, or authored templates
    /// that call `joryioBridge.closeMessage(...)` silently do nothing.
    private static let bridgeName = "joryioBridge"

    private let backdrop = UIView()
    private let container = UIView()
    private var webView: WKWebView!
    private var heightConstraint: NSLayoutConstraint?

    private let html: String
    private let css: String
    /// The message document's own load has been allowed. Every navigation
    /// after it is cancelled (SDK contract v5, 57).
    private var initialLoadStarted = false

    /// Returns nil when the campaign carries no renderable document.
    ///
    /// An empty container the user has to dismiss is worse than no message, and
    /// counting an impression for it would inflate the campaign's reach - so
    /// this refuses to construct rather than presenting a blank.
    ///
    /// A factory rather than a failable `init?`: Swift forbids a failable
    /// initializer overriding BaseMessageView's non-failable one.
    static func make(campaign: InAppCampaign, delegate: InAppMessageViewDelegate?) -> InAppWebMessageView? {
        guard case let .html(html, css)? = campaign.content, !html.isEmpty else {
            return nil
        }
        return InAppWebMessageView(campaign: campaign, delegate: delegate, html: html, css: css)
    }

    private init(campaign: InAppCampaign, delegate: InAppMessageViewDelegate?, html: String, css: String) {
        self.html = html
        self.css = css
        super.init(campaign: campaign, delegate: delegate)
        setupViews()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Only the screen-blocking types dim the app. A banner or slide-up that
        // dimmed the screen would read as blocking, when the whole point of
        // those types is that the app stays usable behind them.
        let dims = campaign.type == .modal || campaign.type == .fullscreen
        backdrop.backgroundColor = dims
            ? UIColor.black.withAlphaComponent(0.4)
            : .clear
        backdrop.isUserInteractionEnabled = dims
        blocksBackground = dims
        interactionArea = container
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        if dims {
            backdrop.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
            )
        }

        container.backgroundColor = .clear
        container.clipsToBounds = true
        container.layer.cornerRadius = campaign.type == .fullscreen ? 0 : 14
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        let config = WKWebViewConfiguration()
        config.userContentController.add(BridgeProxy(self), name: Self.bridgeName)
        // The shim is injected rather than concatenated into the document so a
        // template with a stray `</script>` cannot terminate it early.
        config.userContentController.addUserScript(
            WKUserScript(source: shimSource(), injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = campaign.type == .fullscreen
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        applyPlacement()
    }

    /// Placement per type - the only thing the six old view classes really did.
    private func applyPlacement() {
        let guide = safeAreaLayoutGuide

        switch campaign.type {
        case .fullscreen:
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

        case .banner:
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
                container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            setContentHeight(120)

        case .slideup:
            NSLayoutConstraint.activate([
                container.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
                container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            setContentHeight(160)

        case .modal, .custom:
            NSLayoutConstraint.activate([
                container.centerYAnchor.constraint(equalTo: centerYAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            ])
            setContentHeight(240)
        }
    }

    /// Height tracks the content, driven by the bridge's `setSize`, and is
    /// capped so a runaway document cannot cover the whole screen in a type
    /// that is meant to be partial.
    private func setContentHeight(_ height: CGFloat) {
        guard campaign.type != .fullscreen else { return }
        let cap = UIScreen.main.bounds.height * 0.9
        let value = min(max(height, 1), cap)

        if let existing = heightConstraint {
            existing.constant = value
        } else {
            let c = container.heightAnchor.constraint(equalToConstant: value)
            c.isActive = true
            heightConstraint = c
        }
        layoutIfNeeded()
    }

    /**
     A Content-Security-Policy for the message document.

     `script-src 'none'` is deliberate and stronger than the web SDK's nonce:
     this document contains NO inline script at all - the bridge shim is
     injected as a WKUserScript, which WebKit exempts from the page's CSP. So
     nothing legitimate needs to execute, and anything that survives the
     server's sanitiser cannot.

     The media directives are the mixed-content control Android enforced with
     MIXED_CONTENT_NEVER_ALLOW and iOS had no equivalent for: an origin-less
     document has no "mixed" for WebKit to detect, so the restriction has to be
     stated. `upgrade-insecure-requests` upgrades an author's http image rather
     than simply breaking it.

     style-src stays permissive because the server's sanitiser ALLOWS style=""
     attributes; styles cannot execute.
     */
    private static let contentSecurityPolicyMeta = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src https: data:; media-src https: data:; font-src https: data:; connect-src 'none'; form-action 'none'; base-uri 'none'; upgrade-insecure-requests">
        """

    // MARK: - Content

    private func load() {
        let document = """
        <!DOCTYPE html>
        <html>
        <head>
        \(Self.contentSecurityPolicyMeta)
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
          html,body{margin:0;padding:0;background:transparent;}
          /* Responsive by default: an authored image keeps its intrinsic size
             otherwise, so anything wider than the device overflows and the
             message can be scrolled sideways. Declared BEFORE the author
             stylesheet, so an explicit width still wins. height:auto keeps the
             aspect ratio when only the width is constrained. */
          img,video{max-width:100%;height:auto;}
          \(campaign.type == .fullscreen ? "html,body{height:100%;}" : "")
        </style>
        <style>\(Self.styleSafe(css))</style>
        </head>
        <body>\(html)</body>
        </html>
        """
        // nil baseURL: the document gets no origin, so it cannot reach
        // app-local files or same-origin storage.
        webView.loadHTMLString(document, baseURL: nil)
    }

    /**
     Author CSS made safe to put inside `<style>` (SDK contract v5, 57).

     `</` is written `<\/`: inside CSS the backslash only escapes the `/`, so
     the rules are unchanged, but the HTML parser can no longer see a
     `</style>` - CSS that closed the element used to add a
     `<meta http-equiv="refresh">` that loaded any remote page into the
     message, bridge attached.
     */
    static func styleSafe(_ css: String) -> String {
        css.replacingOccurrences(of: "</", with: "<\\/")
    }

    /**
     The shim injected into every message.

     Tags the device class so the editor's "mobile only" / "desktop only" rules
     resolve, and reports content height so a non-fullscreen message is exactly
     as tall as its content. Images and web fonts land after `load` and change
     the height, so a single measurement would leave messages clipped - hence
     the ResizeObserver.
     */
    private func shimSource() -> String {
        let cid = campaign.id.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (function(){
          var CID = "\(cid)";
          try {
            document.documentElement.className +=
              (window.innerWidth <= 480 ? ' jr-vp-mobile' : ' jr-vp-desktop');
          } catch (e) {}

          function post(method, args) {
            try {
              window.webkit.messageHandlers.\(Self.bridgeName).postMessage({
                method: method, campaignId: CID, args: args || {}
              });
            } catch (e) {}
          }

          // Same surface as the web SDK's joryioBridge, so one authored
          // template works on web, Android and iOS unchanged. Every method
          // takes the same arguments as on web; the campaign id the web
          // bootstrap prepends is implied here (one WebView per message).
          var pending = {};
          var seq = 0;
          window.__joryioFormResult = function(id, result) {
            var p = pending[id]; delete pending[id];
            if (p) { p(result || {ok: false}); }
          };
          window.\(Self.bridgeName) = {
            logCustomEvent: function(name, props){ post('logCustomEvent', {name: name, properties: props || {}}); },
            setCustomUserAttribute: function(k, v){ post('setCustomUserAttribute', {key: k, value: v}); },
            changeUser: function(uid){ post('changeUser', {userId: uid}); },
            requestPushPermission: function(){ post('requestPushPermission', {}); },
            logConversion: function(ev){ post('logConversion', {event: ev || 'in_app_conversion'}); },
            logClick: function(action){ post('trackClick', {action: action}); },
            trackClick: function(cid, action){ post('trackClick', {action: action}); },
            closeMessage: function(){ post('closeMessage', {}); },
            navigate: function(url, target){
              // Web passes (url, target); the older native shape was (cid, url, target).
              if (typeof target === 'string' && /^https?:/i.test(target) && !/^https?:/i.test(String(url))) { url = target; target = arguments[2]; }
              post('navigate', {url: url, target: target});
            },
            setSize: function(cid, h){ post('setSize', {height: h}); },
            openUrl: function(url){ post('openUrl', {url: url}); },
            submitForm: function(values){
              return new Promise(function(resolve){
                var id = 'f' + (++seq);
                pending[id] = resolve;
                post('submitForm', {requestId: id, values: values || {}});
              });
            }
          };

          // data-joryio-action buttons and plain links, as on web: the sandbox
          // cannot navigate the app, so links go through the bridge.
          document.addEventListener('click', function(e){
            var el = e.target;
            while (el && el !== document.body && el !== document.documentElement) {
              var action = el.getAttribute && el.getAttribute('data-joryio-action');
              if (action && typeof window.\(Self.bridgeName)[action] === 'function') { e.preventDefault(); window.\(Self.bridgeName)[action](el.getAttribute('data-joryio-event') || undefined); return; }
              var tag = el.tagName;
              if (tag === 'A' || tag === 'BUTTON') {
                // As on web: every link and button click is reported, named by
                // data-action when the author gave one. A link opens outside
                // the message without a second click event.
                if (el.type === 'submit') { return; }
                var da = el.getAttribute('data-action');
                var href = tag === 'A' ? el.getAttribute('href') : null;
                post('trackClick', {action: da || (href ? 'link_click' : 'cta_click')});
                if (href && /^(https?:\\/\\/|\\/(?!\\/))/i.test(href)) { e.preventDefault(); post('openUrl', {url: href}); }
                return;
              }
              el = el.parentNode;
            }
          }, true);

          // Forms (data-jry-form): serialise, hand the values to the app, show
          // the answer in place. A redirect goes through navigate.
          document.addEventListener('submit', function(ev){
            var f = ev.target;
            if (!(f && f.tagName === 'FORM' && f.hasAttribute('data-jry-form'))) return;
            ev.preventDefault();
            if (f.getAttribute('data-jry-busy')) return;
            var d = {}, els = f.querySelectorAll('input,select,textarea');
            for (var i = 0; i < els.length; i++) {
              var el = els[i], n = el.name; if (!n || el.disabled) continue;
              if (el.type === 'checkbox') { if (!el.checked) continue; if (d[n] === undefined) d[n] = []; d[n].push(el.value || 'on'); }
              else if (el.type === 'radio') { if (el.checked) d[n] = el.value; }
              else d[n] = el.value;
            }
            function msg(text, ok){
              var b = f.querySelector('[data-jry-message]');
              if (!b) { b = document.createElement('div'); b.setAttribute('data-jry-message', ''); b.setAttribute('role', 'status'); f.appendChild(b); }
              b.textContent = text; b.className = ok ? 'jry-form-success' : 'jry-form-error';
            }
            f.setAttribute('data-jry-busy', '1');
            var btn = f.querySelector('button[type="submit"],input[type="submit"]'); if (btn) btn.disabled = true;
            post('trackClick', {action: 'form_submit'});
            window.\(Self.bridgeName).submitForm(d).then(function(r){
              if (r && r.ok) {
                if (r.redirect) { window.\(Self.bridgeName).navigate(r.redirect, '_top'); return; }
                var all = f.querySelectorAll('input,select,textarea,button'); for (var j = 0; j < all.length; j++) { all[j].disabled = true; }
                msg(r.message || 'Thank you.', true);
              } else {
                msg((r && (r.message || (r.errors && r.errors[0]))) || 'Something went wrong. Please try again.', false);
                f.removeAttribute('data-jry-busy'); if (btn) btn.disabled = false;
              }
            });
          }, true);

          function report() {
            try {
              var h = Math.max(
                document.body ? document.body.scrollHeight : 0,
                document.documentElement ? document.documentElement.scrollHeight : 0
              );
              if (h > 0) post('setSize', {height: h});
            } catch (e) {}
          }
          window.addEventListener('load', report);
          if (window.ResizeObserver && document.body) {
            new ResizeObserver(report).observe(document.body);
          }
          setTimeout(report, 60);
        })();
        """
    }

    // MARK: - Bridge

    fileprivate func handle(method: String, args: [String: Any]) {
        switch method {
        case "setSize":
            if let h = args["height"] as? NSNumber {
                setContentHeight(CGFloat(truncating: h))
            }
        case "closeMessage":
            dismiss()
        case "trackClick":
            let action = (args["action"] as? String) ?? "click"
            delegate?.messageViewClicked(campaign.id, action: action, url: nil)
        case "navigate":
            guard let url = args["url"] as? String else { return }
            delegate?.messageViewClicked(campaign.id, action: "link", url: url)
        case "openUrl":
            // A link the bootstrap already reported as a click: open it, count nothing.
            guard let raw = args["url"] as? String, let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        // The rest of the web bridge (BACKLOG C23, 2026-09-26): a message script
        // that records an event or an attribute used to do nothing here.
        case "logCustomEvent":
            guard let name = args["name"] as? String, !name.isEmpty else { return }
            Joryio.shared.track(name, properties: (args["properties"] as? [String: Any]) ?? [:])
        case "setCustomUserAttribute":
            guard let key = args["key"] as? String, !key.isEmpty, let value = args["value"] else { return }
            Joryio.shared.setAttribute(key, value: value)
        case "changeUser":
            guard let userId = args["userId"] as? String, !userId.isEmpty else { return }
            Joryio.shared.identify(userId)
        case "requestPushPermission":
            Task { _ = await Joryio.shared.requestPushPermission() }
        case "logConversion":
            Joryio.shared.trackInAppImpression(campaignId: campaign.id, action: "converted")
        case "submitForm":
            guard let requestId = args["requestId"] as? String else { return }
            let values = (args["values"] as? [String: Any]) ?? [:]
            let campaignId = campaign.id
            Task { [weak self] in
                let result = await Joryio.shared.submitInAppForm(campaignId: campaignId, values: values)
                await MainActor.run { self?.deliverFormResult(requestId: requestId, result: result) }
            }
        default:
            break
        }
    }

    /// Hand the server's answer back to the message's promise.
    private func deliverFormResult(requestId: String, result: InAppFormSubmitResponse) {
        guard let data = try? JSONEncoder().encode(result), let json = String(data: data, encoding: .utf8) else { return }
        let id = requestId.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("window.__joryioFormResult('\(id)', \(json));", completionHandler: nil)
    }

    @objc private func backdropTapped() {
        dismiss()
    }

    /**
     WKScriptMessageHandler is retained by the configuration, and the
     configuration is retained by the web view, which the view owns - a direct
     conformance would be a retain cycle that leaks a WebView per message.
     */
    private final class BridgeProxy: NSObject, WKScriptMessageHandler {
        weak var owner: InAppWebMessageView?
        init(_ owner: InAppWebMessageView) { self.owner = owner }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                let body = message.body as? [String: Any],
                let method = body["method"] as? String
            else { return }
            owner?.handle(method: method, args: (body["args"] as? [String: Any]) ?? [:])
        }
    }
}

extension InAppWebMessageView: WKNavigationDelegate {
    /**
     The web view loads ONE document - the message - and nothing else (SDK
     contract v5, 57).

     Only the initial `loadHTMLString` (about:blank, main frame) is allowed.
     Every other navigation is cancelled: a meta refresh, a form, a script
     redirect, a frame. Everything except a user's link tap used to be
     allowed, so a meta refresh smuggled in through the CSS replaced the
     message with a remote page that ran its own scripts with the Joryio
     bridge (identify, attributes, push prompt) attached.

     A link the user taps opens outside the message (http(s) only - the same
     rule as web and Android: `javascript:`, `data:` and `file:` URLs are how
     authored content escapes its container).
     */
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(decide(
            url: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
            isLinkActivated: navigationAction.navigationType == .linkActivated
        ))
    }

    /// The navigation rule, separated so it is testable without WebKit.
    func decide(url: URL?, isMainFrame: Bool, isLinkActivated: Bool) -> WKNavigationActionPolicy {
        if !initialLoadStarted, !isLinkActivated, isMainFrame, url?.absoluteString == "about:blank" {
            initialLoadStarted = true
            return .allow
        }
        if isLinkActivated, let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            delegate?.messageViewClicked(campaign.id, action: "link", url: url.absoluteString)
        }
        return .cancel
    }
}
