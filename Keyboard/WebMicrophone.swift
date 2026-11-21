import UIKit
import WebKit

/// The recorder behind in-keyboard capture: a hidden 2×2 pt `WKWebView` whose page calls
/// `getUserMedia({audio: true})`. A keyboard extension may not record through AVFoundation
/// ("is an extension and doesn't have entitlements to record audio"), but WebKit's media
/// (GPU) process records on the page's behalf under the containing app's microphone permission;
/// the `WKUIDelegate` grants the page's media-capture request for the microphone only. The page
/// posts 16-bit little-endian mono PCM chunks back to Swift.
///
/// Technique as shipped and verified on device by the Hex project (anomalyco/hex#1999, MIT:
/// iPhone 17 Pro, iOS 27.2); unverified on Scriber's device builds so far.
///
/// Secure context: `getUserMedia` only exists on `navigator.mediaDevices` in a secure context.
/// The page is loaded from a string with an `https:` base URL, which gives the document an https
/// origin (potentially trustworthy by scheme) without any network request (the page loads no
/// subresources). The host is under `.invalid` (RFC 2606), so it can never resolve to anything.
///
/// Message format (page → Swift, `window.webkit.messageHandlers.scriber`), one dictionary each:
///   {type:"ready",   secure:Bool, mediaDevices:Bool, loadMs:Int}       page script ran
///   {type:"started", rate:Double, micMs:Int, totalMs:Int}              mic + AudioContext running
///   {type:"pcm",     seq:Int, data:String(base64 Int16 LE mono)}       ~4096 frames (~85 ms @ 48 kHz)
///   {type:"ended"}                                                     track ended by itself
///   {type:"stopped", wasRunning:Bool, chunks:Int}                      after scriberStop(); mic released
///   {type:"error",   stage:String, name:String, message:String}        e.g. NotAllowedError
/// Swift → page: `scriberStart()` / `scriberStop()`.
@MainActor
final class WebMicrophone: NSObject {
    enum Event {
        case ready(secure: Bool, mediaDevices: Bool, loadMillis: Int)
        case started(sampleRate: Double, micMillis: Int, totalMillis: Int)
        case chunk(Data, seq: Int)
        case ended
        case stopped(chunks: Int)
        case failed(stage: String, name: String, message: String)
    }

    static let baseURL = URL(string: "https://keyboard.scriber.invalid/")!
    static let handlerName = "scriber"

    var onEvent: ((Event) -> Void)?
    private var webView: WKWebView?
    private var isReady = false
    private var startWhenReady = false
    private let createdAt = Date()

    init(host: UIView) {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: Self.handlerName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.alpha = 0.02 // visible to WebKit (fully hidden views can be throttled), invisible to people
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        host.addSubview(webView)
        self.webView = webView
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
    }

    var isAlive: Bool { webView != nil }

    func start() {
        guard isReady else {
            startWhenReady = true
            return
        }
        run("window.scriberStart(); undefined")
    }

    /// Stops the tracks and closes the AudioContext; a `.stopped` event follows.
    func stop() {
        startWhenReady = false
        guard isReady else {
            onEvent?(.stopped(chunks: 0))
            return
        }
        run("window.scriberStop(); undefined")
    }

    /// Removes the web view; WebKit's content process and its capture go with it.
    func tearDown() {
        onEvent = nil
        startWhenReady = false
        guard let webView else { return }
        self.webView = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.removeFromSuperview()
    }

    private func run(_ script: String) {
        webView?.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            self?.onEvent?(.failed(stage: "evaluate", name: (error as NSError).domain + "." + String((error as NSError).code),
                                   message: (error as NSError).localizedDescription))
        }
    }

    // MARK: Page

    /// ScriptProcessor rather than AudioWorklet: it is what the device-verified implementation
    /// used, needs no module URL, and 4096-frame callbacks are plenty for dictation. No echo
    /// cancellation, noise suppression or AGC: STT wants the voice as spoken.
    static let page = """
    <!doctype html><html><head><meta charset="utf-8"></head><body><script>
    "use strict";
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.scriber.postMessage(m); } catch (e) {} };
      const loadedAt = performance.now();
      let ctx = null, stream = null, source = null, node = null, running = false, generation = 0, seq = 0;
      const release = (s, c) => {
        try { if (s) s.getTracks().forEach((t) => { t.onended = null; t.stop(); }); } catch (e) {}
        if (c) c.close().catch(() => {});
      };
      const base64 = (bytes) => {
        let binary = "";
        for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        return btoa(binary);
      };
      async function start() {
        if (running) return;
        running = true;
        const gen = ++generation;
        seq = 0;
        const begun = performance.now();
        const md = navigator.mediaDevices;
        if (!window.isSecureContext || !md || typeof md.getUserMedia !== "function") {
          running = false;
          post({ type: "error", stage: "mediaDevices", name: "NotSupportedError",
                 message: "secure=" + window.isSecureContext + " mediaDevices=" + !!md });
          return;
        }
        let s = null, c = null, stage = "getUserMedia";
        try {
          s = await md.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false }, video: false });
          if (gen !== generation) { release(s, null); return; }
          const micAt = performance.now();
          stage = "audioContext";
          c = new (window.AudioContext || window.webkitAudioContext)();
          if (c.state !== "running") await c.resume();
          if (gen !== generation) { release(s, c); return; }
          stream = s; ctx = c;
          const track = s.getAudioTracks()[0];
          if (track) track.onended = () => { if (gen === generation && running) post({ type: "ended" }); };
          stage = "graph";
          source = ctx.createMediaStreamSource(s);
          node = ctx.createScriptProcessor(4096, 1, 1);
          node.onaudioprocess = (event) => {
            if (!running || gen !== generation) return;
            const input = event.inputBuffer.getChannelData(0);
            const pcm = new Int16Array(input.length);
            for (let i = 0; i < input.length; i++) {
              const v = Math.max(-1, Math.min(1, input[i]));
              pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
            }
            post({ type: "pcm", seq: seq++, data: base64(new Uint8Array(pcm.buffer)) });
          };
          source.connect(node);
          node.connect(ctx.destination); // a ScriptProcessor only runs when connected; its output is silence
          post({ type: "started", rate: ctx.sampleRate, micMs: Math.round(micAt - begun), totalMs: Math.round(performance.now() - begun) });
        } catch (error) {
          if (gen !== generation) { release(s, c); return; }
          running = false;
          release(s, c);
          post({ type: "error", stage, name: (error && error.name) || "Error", message: String((error && error.message) || error) });
        }
      }
      async function stop() {
        const wasRunning = running;
        generation++;
        running = false;
        try { if (node) { node.onaudioprocess = null; node.disconnect(); } if (source) source.disconnect(); } catch (e) {}
        const s = stream, c = ctx;
        ctx = stream = source = node = null;
        release(s, null);
        if (c) { try { await c.close(); } catch (e) {} }
        post({ type: "stopped", wasRunning, chunks: seq });
      }
      window.scriberStart = start;
      window.scriberStop = stop;
      post({ type: "ready", secure: window.isSecureContext === true,
             mediaDevices: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
             loadMs: Math.round(performance.now() - loadedAt) });
    })();
    </script></body></html>
    """
}

// MARK: - Script messages

extension WebMicrophone: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only our own page, in the main frame, may talk to us.
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == Self.baseURL.host,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let int = { (key: String) -> Int in (body[key] as? NSNumber)?.intValue ?? 0 }
        switch type {
        case "ready":
            isReady = true
            onEvent?(.ready(secure: body["secure"] as? Bool ?? false, mediaDevices: body["mediaDevices"] as? Bool ?? false,
                            loadMillis: Int(Date().timeIntervalSince(createdAt) * 1000)))
            if startWhenReady {
                startWhenReady = false
                start()
            }
        case "started":
            onEvent?(.started(sampleRate: (body["rate"] as? NSNumber)?.doubleValue ?? 48_000,
                              micMillis: int("micMs"), totalMillis: int("totalMs")))
        case "pcm":
            guard let encoded = body["data"] as? String, let data = Data(base64Encoded: encoded) else { return }
            onEvent?(.chunk(data, seq: int("seq")))
        case "ended":
            onEvent?(.ended)
        case "stopped":
            onEvent?(.stopped(chunks: int("chunks")))
        case "error":
            onEvent?(.failed(stage: body["stage"] as? String ?? "?", name: body["name"] as? String ?? "Error",
                             message: body["message"] as? String ?? ""))
        default:
            break
        }
    }
}

// MARK: - Navigation and permissions

extension WebMicrophone: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The string we load is the only document this view may ever show.
        let url = navigationAction.request.url
        let ours = url?.host == Self.baseURL.host || url?.scheme == "about"
        decisionHandler(ours ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let ours = origin.host == Self.baseURL.host && origin.protocol == "https" && frame.isMainFrame
        let grant = ours && type == .microphone
        KBLog.log("local webkit media permission request type=\(type.rawValue) ours=\(ours) → \(grant ? "grant" : "deny")")
        decisionHandler(grant ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        onEvent?(.failed(stage: "load", name: "\(ns.domain).\(ns.code)", message: ns.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        onEvent?(.failed(stage: "load", name: "\(ns.domain).\(ns.code)", message: ns.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        onEvent?(.failed(stage: "process", name: "WebContentProcessTerminated", message: ""))
    }
}

/// `WKUserContentController` retains its handlers; this keeps it from retaining the recorder.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
