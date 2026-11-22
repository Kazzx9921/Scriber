import Foundation

/// `MediaControlPort` through Apple's `/usr/bin/osascript` (see the notes at the top of
/// `MediaPause.swift` for why). Each call starts one short-lived osascript process (≈ 0.1–0.2 s,
/// plus up to ~1 s while it confirms a pause or play) on a background queue; the completion runs
/// on the main thread. A process that does not finish within `timeout` is terminated and reported
/// as unavailable.
///
/// The script never reads titles, artists or anything else about what is playing: only whether
/// the now-playing app is playing, its bundle id and pid.
@MainActor
final class MediaRemoteScript: MediaControlPort {
    nonisolated static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    nonisolated static let timeout: TimeInterval = 4

    /// Arguments: `state` | `pause` | `play <bundle> <pid>`, optionally followed by `dry` (does
    /// everything except sending the command; used by the tests on the read-only paths).
    /// Commands: 0 = play, 1 = pause (MRMediaRemoteCommand). Never 2 (toggle).
    nonisolated static let source = #"""
    function run(argv) {
      var mode = argv[0] || 'state';
      var dry = argv.indexOf('dry') >= 0;
      var out = { ok: false };
      var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
      if (bundle.isNil() || !bundle.load) { out.error = 'load'; return JSON.stringify(out); }
      var R = $.NSClassFromString('MRNowPlayingRequest');
      if (R.isNil() || !R.respondsToSelector('localIsPlaying') || !R.respondsToSelector('localNowPlayingPlayerPath')) {
        out.error = 'api'; return JSON.stringify(out);
      }
      function state() {
        var s = { playing: R.localIsPlaying === true, bundle: '', pid: 0 };
        var path = R.localNowPlayingPlayerPath;
        if (!path.isNil()) {
          var client = path.client;
          if (!client.isNil()) {
            var id = client.bundleIdentifier;
            s.bundle = id.isNil() ? '' : id.js;
            s.pid = client.processIdentifier;
          }
        }
        return s;
      }
      function waitFor(playing) {
        var s = state();
        for (var i = 0; i < 6 && s.playing !== playing; i++) { delay(0.2); s = state(); }
        return s;
      }
      out.ok = true;
      out.before = state();
      if (mode === 'state') { return JSON.stringify(out); }
      ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
      if (typeof $.MRMediaRemoteSendCommand !== 'function') { out.ok = false; out.error = 'command'; return JSON.stringify(out); }
      if (mode === 'pause') {
        if (!out.before.playing && !dry) { return JSON.stringify(out); }
        out.sent = dry ? false : $.MRMediaRemoteSendCommand(1, null) === true;
        out.after = dry ? state() : waitFor(false);
        return JSON.stringify(out);
      }
      if (mode === 'play') {
        if (out.before.playing) { out.skip = 'already-playing'; return JSON.stringify(out); }
        if (out.before.bundle !== (argv[1] || '') || String(out.before.pid) !== String(argv[2] || '0')) {
          out.skip = 'other-app'; return JSON.stringify(out);
        }
        out.sent = dry ? false : $.MRMediaRemoteSendCommand(0, null) === true;
        out.after = dry ? state() : waitFor(true);
        return JSON.stringify(out);
      }
      out.ok = false; out.error = 'mode'; return JSON.stringify(out);
    }
    """#

    func probe(_ completion: @escaping @MainActor (MediaAvailability) -> Void) {
        Self.run(["state"]) { report, failure in
            completion(report?.availability ?? .unavailable(failure))
        }
    }

    func pauseIfPlaying(_ completion: @escaping @MainActor (MediaPauseResult) -> Void) {
        Self.run(["pause"]) { report, failure in
            completion(report?.pauseResult ?? .unavailable(failure))
        }
    }

    func resume(_ app: NowPlayingApp, _ completion: @escaping @MainActor (MediaResumeResult) -> Void) {
        Self.run(["play", app.bundle, String(app.pid)]) { report, failure in
            completion(report?.resumeResult ?? .unavailable(failure))
        }
    }

    func resumeDetached(_ app: NowPlayingApp) {
        let process = Self.makeProcess(["play", app.bundle, String(app.pid)])
        // The child keeps running after Scriber exits.
        try? process.run()
    }

    // MARK: Process

    nonisolated private static func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = osascript
        process.arguments = ["-l", "JavaScript", "-e", source] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        return process
    }

    /// Runs the script; `completion(report, failureToken)` on the main thread.
    nonisolated static func run(_ arguments: [String], timeout: TimeInterval = timeout,
                                completion: @escaping @MainActor (MediaScriptReport?, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (report, failure) = runBlocking(arguments, timeout: timeout)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(report, failure) }
            }
        }
    }

    /// Blocking variant (background threads and tests only).
    nonisolated static func runBlocking(_ arguments: [String], timeout: TimeInterval = timeout) -> (MediaScriptReport?, String) {
        guard FileManager.default.isExecutableFile(atPath: osascript.path) else { return (nil, "no-osascript") }
        let process = makeProcess(arguments)
        let output = Pipe()
        process.standardOutput = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return (nil, "launch-failed")
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return (nil, "timeout")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return (nil, "exit-\(process.terminationStatus)") }
        guard let text = String(data: data, encoding: .utf8), let report = MediaScriptReport.parse(text) else {
            return (nil, "bad-output")
        }
        return (report, report.error ?? "")
    }
}
