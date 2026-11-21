import AppKit
import ScriberShared

/// Puts text at the cursor of the frontmost app: borrow the pasteboard, post ⌘V, give the
/// pasteboard back. Our UI never takes focus, so ⌘V lands in the app the user is typing in.
///
/// When pasting cannot work (no Accessibility permission, secure input on) the text is left on the
/// clipboard as an ordinary copy and the caller shows "已複製，請按 ⌘V". The last results also
/// stay in the menu (複製上一段), so nothing is ever lost.
@MainActor
final class TextInserter {
    enum Outcome: Equatable {
        case pasted
        case copied(HUDFeedback)
    }

    /// A borrowed pasteboard waiting to be given back.
    private struct PendingRestore {
        var snapshot: PasteboardSnapshot
        var ourChangeCount: Int
        var work: DispatchWorkItem
    }

    private var pending: PendingRestore?

    /// `restoreClipboard` false: do not read (or give back) the user's clipboard at all.
    func insert(_ text: String, requestID: String, restoreClipboard: Bool) async -> Outcome {
        let tag = MacDiag.id(requestID)
        let pasteboard = NSPasteboard.general
        let front = NSWorkspace.shared.frontmostApplication

        guard Permissions.isAccessibilityTrusted else {
            copyForManualPaste(text)
            DiagLog.log("paste", "id=\(tag) not pasted: no accessibility → copied for ⌘V")
            return .copied(.copiedNoAccessibility())
        }
        if Permissions.secureInputActive {
            let owner = Permissions.secureInputOwner()
            copyForManualPaste(text)
            DiagLog.log("paste", "id=\(tag) not pasted: secure input on owner=\(MacDiag.app(owner)) front=\(MacDiag.app(front)) → copied for ⌘V")
            return .copied(.copiedSecureInput(appName: owner?.localizedName))
        }

        // The user's clipboard. If a previous paste has not been given back yet, its snapshot is
        // still the user's real clipboard (the pasteboard holds our earlier temporary item).
        var snapshot: PasteboardSnapshot?
        var snapshotSource = "none"
        if let previous = pending {
            previous.work.cancel()
            pending = nil
            if pasteboard.changeCount == previous.ourChangeCount {
                snapshot = previous.snapshot
                snapshotSource = "pending"
            }
        }
        if snapshot == nil {
            if !restoreClipboard {
                snapshotSource = "skipped(setting off)"
            } else if Permissions.canReadPasteboard {
                let started = Date()
                let captured = PasteboardSnapshot.capture(from: pasteboard)
                snapshot = captured
                snapshotSource = "captured items=\(captured.items.count) types=\(captured.typeCount) "
                    + "kb=\(captured.byteCount / 1024) ms=\(MacDiag.millis(since: started))"
            } else {
                snapshotSource = "skipped(pasteboard access denied)"
            }
        }

        let ours = PasteboardMarkers.writeTemporary(text, to: pasteboard, sourceBundleID: Bundle.main.bundleIdentifier)
        let modifiersReleased = await SyntheticKeys.waitForModifiersReleased()
        let keyCode = KeyboardLayout.keyCode(for: "v", fallback: KeyCodes.ansiV)
        let role = FocusInfo.focusedRole()
        guard SyntheticKeys.postCommand(keyCode: keyCode) else {
            pending = nil
            copyForManualPaste(text)
            DiagLog.log("paste", "id=\(tag) could not create ⌘V events → copied for ⌘V")
            return .copied(.copiedPasteFailed())
        }
        DiagLog.log("paste", "id=\(tag) ⌘V posted front=\(MacDiag.app(front)) role=\(role) keyCode=\(keyCode) "
                    + "modsReleased=\(modifiersReleased) chars=\(text.count) clipboard=\(snapshotSource) "
                    + "access=\(Permissions.pasteboardAccess)")

        if let snapshot {
            scheduleRestore(snapshot, ourChangeCount: ours, tag: tag)
        } else {
            DiagLog.log("paste", "id=\(tag) clipboard will not be restored (\(snapshotSource)); the dictated text stays on it")
        }
        return .pasted
    }

    /// Plain copy for the user to paste themselves (menu 複製上一段, or when pasting cannot work).
    func copyForManualPaste(_ text: String) {
        // A plain copy replaces whatever we were going to give back.
        pending?.work.cancel()
        pending = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Gives a pending pasteboard back right away (e.g. when the app quits).
    func flushPendingRestore() {
        guard let pending else { return }
        pending.work.cancel()
        restore(pending, tag: "flush")
    }

    private func scheduleRestore(_ snapshot: PasteboardSnapshot, ourChangeCount: Int, tag: String) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.pending, current.ourChangeCount == ourChangeCount else { return }
                self.restore(current, tag: tag)
            }
        }
        pending = PendingRestore(snapshot: snapshot, ourChangeCount: ourChangeCount, work: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + PasteRestorePolicy.restoreDelay, execute: work)
    }

    private func restore(_ entry: PendingRestore, tag: String) {
        pending = nil
        let pasteboard = NSPasteboard.general
        guard PasteRestorePolicy.shouldRestore(snapshot: entry.snapshot, ourChangeCount: entry.ourChangeCount,
                                               currentChangeCount: pasteboard.changeCount) else {
            DiagLog.log("paste", "id=\(tag) clipboard not restored: changed by someone else meanwhile")
            return
        }
        entry.snapshot.restore(to: pasteboard)
        DiagLog.log("paste", "id=\(tag) clipboard restored items=\(entry.snapshot.items.count)")
    }
}
