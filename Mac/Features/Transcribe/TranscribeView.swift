import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ScriberCore
import ScriberShared

/// 轉錄: drop audio or video files (or 選擇檔案…) and get a transcript. Files queue up and run one
/// at a time; each shows progress, the text so far and cancel. Saved transcripts are listed below
/// and open in the same page. Needs only the speech engine's API key (no Accessibility, no microphone).
struct TranscribeView: View {
    let store: TranscriptStore
    let queue: TranscriptionQueue
    /// Snapshots: open this transcript instead of the page.
    var initiallyOpen: UUID?
    /// Snapshots: draw the drop zone as if files were dragged over it.
    var forceDropTarget = false
    /// Snapshots: fixed options instead of the saved ones.
    var initialOptions: TranscriptionOptions?

    @Environment(MacSettings.self) private var settings
    @State private var options = TranscriptionOptions.load()
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var openID: UUID?
    @State private var keySheet: KeySheetItem?
    @State private var pending: [URL] = []
    @State private var renaming: TranscriptSummary?
    @State private var renameText = ""
    @State private var deleting: TranscriptSummary?
    @State private var copiedID: UUID?
    @State private var didApplyInitial = false

    static let info = "音檔、影片都可以，長度不限。檔案會在這台 Mac 轉成小音檔、分段送到你在設定選的語音辨識服務；逐字稿只存在這台 Mac。"
    static let allowedTypes: [UTType] = [.audiovisualContent, .audio, .movie]

    private var capabilities: FileTranscriptionCapabilities { FileTranscriberFactory.capabilities(of: settings.sttProvider) }

    var body: some View {
        Group {
            if let id = openID, store.items.contains(where: { $0.id == id }) {
                TranscriptDetailView(id: id, store: store, queue: queue) { openID = nil }
            } else {
                page
            }
        }
        .onAppear {
            store.reload()
            guard !didApplyInitial else { return }
            didApplyInitial = true
            if let initialOptions { options = initialOptions }
            if let initiallyOpen { openID = initiallyOpen }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .sheet(item: $keySheet, onDismiss: {
            let files = pending
            pending = []
            if settings.isSTTReady, !files.isEmpty { add(files) }
        }) { item in
            KeyEntrySheet(kind: item.kind) { keySheet = nil }
                .environment(settings)
        }
        .alert("重新命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("儲存") {
                if let item = renaming { store.rename(id: item.id, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog("刪除「\(deleting?.title ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("刪除", role: .destructive) {
                if let item = deleting {
                    store.remove(ids: [item.id])
                    DiagLog.log("transcribe", "transcript deleted")
                }
                deleting = nil
            }
        } message: {
            Text("這個動作無法復原。")
        }
    }

    // MARK: Page

    private var page: some View {
        VStack(spacing: 0) {
            PageHeader(title: "轉錄", subtitle: store.items.isEmpty ? nil : "\(store.items.count) 份逐字稿", info: Self.info)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !settings.isSTTReady {
                            ProblemRow(symbol: "key.fill", text: "需要 \(engineName) 的 API key", actionTitle: "設定 key") {
                                keySheet = KeySheetItem(kind: settings.sttProvider.requiredKey)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .card(radius: 12)
                        }
                        dropZone
                        TranscribeOptionsBar(options: $options, engineName: engineName, capabilities: capabilities)
                    }
                    if !queue.jobs.isEmpty { jobsSection }
                    if !store.items.isEmpty { transcriptsSection }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 2)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: options) { _, value in value.save() }
    }

    private var engineName: String {
        settings.sttProvider == .custom ? settings.customEngineName : settings.sttProvider.rowTitle
    }

    /// Big and centered while the page is empty; a slim strip once there are files or transcripts.
    @ViewBuilder
    private var dropZone: some View {
        if queue.jobs.isEmpty && store.items.isEmpty {
            largeDropZone
        } else {
            compactDropZone
        }
    }

    private var compactDropZone: some View {
        let targeted = dropTargeted || forceDropTarget
        return HStack(spacing: 14) {
            SpotIllustration(symbol: "waveform", size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(targeted ? "放開就開始轉錄" : "把音檔或影片拖到這裡")
                    .font(.body.weight(.semibold))
                Text("長度不限，可以一次放好幾個")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("選擇檔案…") { showImporter = true }
                .prominentAction()
                .help("音訊或影片檔")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(dropBackground(targeted))
        .overlay(dropBorder(targeted))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("把音檔或影片拖到這裡")
    }

    private func dropBackground(_ targeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(targeted ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.02))
    }

    private func dropBorder(_ targeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(targeted ? Theme.accent.opacity(0.75) : Color.primary.opacity(0.14),
                          style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 5]))
    }

    private var largeDropZone: some View {
        let targeted = dropTargeted || forceDropTarget
        return VStack(spacing: 0) {
            SpotIllustration(symbol: "waveform", size: 60)
                .padding(.bottom, 18)
            Text(targeted ? "放開就開始轉錄" : "把音檔或影片拖到這裡")
                .font(.title3.weight(.semibold))
            Text("長度不限，可以一次放好幾個")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Button {
                showImporter = true
            } label: {
                Text("選擇檔案…")
            }
            .prominentAction()
            .controlSize(.large)
            .padding(.top, 18)
            .help("音訊或影片檔")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(dropBackground(targeted))
        .overlay(dropBorder(targeted))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("把音檔或影片拖到這裡")
    }

    // MARK: Jobs

    private var jobsSection: some View {
        let busy = queue.jobs.contains { $0.isActive || $0.phase == .waiting }
        let finished = queue.jobs.contains { $0.phase == .done || $0.phase == .cancelled }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(busy ? "進行中" : "剛完成").font(.title3.weight(.bold))
                Spacer()
                if finished {
                    Button("清除已完成") { withAnimation(.snappy) { queue.clearFinished() } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 10) {
                ForEach(queue.jobs) { job in
                    TranscriptionJobCard(
                        job: job, needsKey: !settings.isSTTReady,
                        onOpen: { openID = job.transcriptID },
                        onCancel: { queue.cancel(job) },
                        onRemove: { withAnimation(.snappy) { queue.remove(job) } },
                        onResume: {
                            if settings.isSTTReady {
                                queue.resume(job)
                            } else {
                                keySheet = KeySheetItem(kind: settings.sttProvider.requiredKey)
                            }
                        },
                        onRetryFailed: { queue.retryFailed(job) })
                }
            }
        }
    }

    // MARK: Saved transcripts

    private var transcriptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("逐字稿").font(.title3.weight(.bold))
            VStack(spacing: 0) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 58) }
                    TranscriptListRow(
                        item: item, copied: copiedID == item.id,
                        onOpen: { openID = item.id },
                        onCopy: { copy(item) },
                        onExport: { format in export(item, format) },
                        onRename: {
                            renameText = item.title
                            renaming = item
                        },
                        onDelete: { deleting = item })
                }
            }
        }
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        guard settings.isSTTReady else {
            pending = files
            keySheet = KeySheetItem(kind: settings.sttProvider.requiredKey)
            return
        }
        var effective = options
        effective.speakers = options.speakers && capabilities.diarization
        queue.add(files, engine: settings.sttProvider, options: effective)
        openID = nil
    }

    private func copy(_ item: TranscriptSummary) {
        guard let record = store.record(id: item.id) else { return }
        TranscriptActions.copy(record, style: TranscriptExport.style(for: record))
        withAnimation(.snappy) { copiedID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedID == item.id { withAnimation(.snappy) { copiedID = nil } }
        }
    }

    private func export(_ item: TranscriptSummary, _ format: TranscriptExport.Format) {
        guard let record = store.record(id: item.id) else { return }
        TranscriptActions.export(record, as: format, style: TranscriptExport.style(for: record))
    }
}

// MARK: - Options

/// Engine (from Settings), language, 時間戳, 說話者 — one quiet row under the drop zone.
struct TranscribeOptionsBar: View {
    @Binding var options: TranscriptionOptions
    let engineName: String
    let capabilities: FileTranscriptionCapabilities

    var body: some View {
        HStack(spacing: 16) {
            Label {
                Text(engineName).lineLimit(1)
            } icon: {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("用設定裡選的語音辨識服務")
            Spacer(minLength: 8)
            Picker("語言", selection: $options.language) {
                ForEach(TranscriptLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Toggle("時間戳", isOn: $options.timestamps)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
            Toggle("說話者", isOn: Binding(get: { options.speakers && capabilities.diarization },
                                       set: { options.speakers = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .disabled(!capabilities.diarization)
                .help(capabilities.diarization ? "標出說話者 1、2…" : "只有 Scribe v3 能分說話者")
            InfoButton {
                InfoItem(title: "時間戳", text: "每段開頭標上時間，例如 [05:07]。")
                InfoItem(title: "說話者", text: "標出說話者 1、2…，只有 Scribe v3 做得到。整個檔案一次送出（最長 15 小時），所以看不到分段進度，長檔案要等久一點。")
                InfoItem(title: "語言", text: "預設中文（夾雜英文也可以）。其他語言選對了會更準。")
                InfoText("不會用 AI 潤飾，只做跟聽寫一樣的整理：去贅字、套用字典、轉成繁體。")
            }
        }
    }
}

// MARK: - Job card

struct TranscriptionJobCard: View {
    let job: TranscriptionJob
    var needsKey = false
    var onOpen: () -> Void
    var onCancel: () -> Void
    var onRemove: () -> Void
    var onResume: () -> Void
    var onRetryFailed: () -> Void

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(statusLine(now: context.date))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            if showsProgress {
                progress
            }
            if job.isActive, !partialTail.isEmpty {
                // The newest lines: the text sits on the bottom of a three-line window, older lines fade out on top.
                Text(partialTail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 60, alignment: .bottom)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0),
                                                 .init(color: .black, location: 0.4)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(.leading, 42)
                    .transition(.opacity)
                    .accessibilityLabel("目前的文字")
            }
            problems
        }
        .padding(14)
        .card(radius: 14)
        .animation(.snappy, value: job.phase)
    }

    private var displayName: String {
        job.sourceExtension.isEmpty ? job.title : "\(job.title).\(job.sourceExtension)"
    }

    private var icon: some View {
        let symbol: String
        switch job.phase {
        case .done: symbol = job.failedSegments.isEmpty ? "checkmark" : "exclamationmark"
        case .failed: symbol = "exclamationmark"
        default: symbol = Self.videoExtensions.contains(job.sourceExtension) ? "film" : "waveform"
        }
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Theme.accent.opacity(0.13)))
            .accessibilityHidden(true)
    }

    private var showsProgress: Bool {
        switch job.phase {
        case .preparing, .transcribing, .finishing, .paused: true
        default: false
        }
    }

    @ViewBuilder
    private var progress: some View {
        Group {
            if job.singleRequest, job.phase != .paused {
                ProgressView().progressViewStyle(.linear)
            } else if job.phase == .preparing {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: job.fraction).progressViewStyle(.linear)
            }
        }
        .tint(Color.primary.opacity(0.55))
        .padding(.leading, 42)
        .accessibilityLabel("進度")
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.phase {
        case .waiting, .preparing, .transcribing, .finishing:
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .help("取消")
            .accessibilityLabel("取消轉錄")
        case .done:
            HStack(spacing: 6) {
                if job.transcriptID != nil {
                    Button("打開", action: onOpen)
                        .quietAction()
                        .controlSize(.small)
                }
                removeButton
            }
        case .paused:
            HStack(spacing: 6) {
                Button("繼續", action: onResume)
                    .quietAction()
                    .controlSize(.small)
                removeButton
            }
        case .failed:
            removeButton
        case .cancelled:
            removeButton
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.secondary)
        .help("從清單移除")
        .accessibilityLabel("從清單移除")
    }

    @ViewBuilder
    private var problems: some View {
        if case .failed(let message) = job.phase {
            // A broken file cannot be retried; a key problem goes to the key first.
            let action: String? = switch job.failureKind {
            case .file?: nil
            case .settings?: needsKey ? "設定 key" : "重試"
            default: "重試"
            }
            ProblemRow(symbol: "exclamationmark.triangle.fill", text: message,
                       actionTitle: action, action: action == nil ? nil : onResume)
                .padding(.leading, 42)
        } else if job.phase == .done, !job.failedSegments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ProblemRow(symbol: "exclamationmark.triangle.fill", text: failedSummary,
                           actionTitle: "重試失敗的段落", action: onRetryFailed)
                if let reason = job.failedSegments.first?.message {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
            .padding(.leading, 42)
        } else if job.speakersUnavailable, job.phase != .cancelled {
            Text("這個檔案不分說話者（只有 Scribe v3、15 小時以內可以）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 42)
        }
    }

    private var failedSummary: String {
        let ranges = job.failedSegments.prefix(2).map {
            "\(TranscriptTime.label($0.start, longForm: job.longForm))–\(TranscriptTime.label($0.end, longForm: job.longForm))"
        }
        let more = job.failedSegments.count > 2 ? " 等" : ""
        return "\(job.failedSegments.count) 段沒有轉錄成功（\(ranges.joined(separator: "、"))\(more)）"
    }

    /// The last few lines of text so far.
    private var partialTail: String {
        let text = job.paragraphs.filter { !$0.isMissing }.map(\.text).joined(separator: " ")
        return text.count > 600 ? String(text.suffix(600)) : text
    }

    private func statusLine(now: Date) -> String {
        var parts: [String] = []
        if let duration = job.duration { parts.append(TranscriptTime.duration(duration)) }
        switch job.phase {
        case .waiting:
            parts.append("排隊中")
        case .preparing:
            parts.append("讀取檔案…")
        case .transcribing:
            if job.singleRequest {
                parts.append("整段辨識中（分說話者）")
                if let started = job.startedAt { parts.append("已過 \(Self.clock(now.timeIntervalSince(started)))") }
            } else {
                parts.append("\(job.segmentsDone)／\(max(job.segmentsTotal, job.segmentsDone)) 段")
                if let remaining = job.estimatedRemaining { parts.append(Self.remaining(remaining)) }
            }
        case .finishing:
            parts.append("整理中…")
        case .done:
            parts.append("完成")
        case .paused:
            parts.append(job.autoPaused ? "已暫停，回到 Scriber 會繼續" : "已中斷，\(job.segmentsDone)／\(max(job.segmentsTotal, job.segmentsDone)) 段完成")
        case .failed:
            parts.append("沒有完成")
        case .cancelled:
            parts.append("已取消")
        }
        return parts.joined(separator: "・")
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "不到 1 分鐘" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "約 \(minutes) 分鐘" }
        return "約 \(minutes / 60) 小時 \(minutes % 60) 分"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        TranscriptTime.label(seconds, longForm: seconds >= 3600)
    }
}

// MARK: - Saved transcript row

struct TranscriptListRow: View {
    let item: TranscriptSummary
    let copied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onExport: (TranscriptExport.Format) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @Environment(\.forcedHover) private var forcedHover

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent.opacity(0.13)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if copied {
                        Label("已拷貝", systemImage: "checkmark")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        Text(meta)
                        if item.missingCount > 0 {
                            Text("\(item.missingCount) 段缺漏")
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if !item.preview.isEmpty {
                    Text(item.preview)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            actions
                .opacity(hovering || forcedHover ? 1 : 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering || forcedHover ? 0.045 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu { menuItems }
        .help("點一下打開")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "打開", onOpen)
        .accessibilityAction(named: "拷貝", onCopy)
    }

    private var meta: String {
        "\(TranscriptListRow.date(item.date))・\(TranscriptTime.duration(item.duration))・\(item.engine.rowTitle)"
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle())
            .help("拷貝")
            Menu {
                exportItems
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("匯出")
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var exportItems: some View {
        ForEach(TranscriptExport.Format.allCases) { format in
            if format != .srt || item.canExportSRT {
                Button(format.displayName) { onExport(format) }
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("打開", action: onOpen)
        Button("拷貝", action: onCopy)
        Menu("匯出") { exportItems }
        Divider()
        Button("重新命名…", action: onRename)
        Button("刪除…", role: .destructive, action: onDelete)
    }

    static func date(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = TimeLabel.clock(date)
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let sameYear = calendar.component(.year, from: now) == parts.year
        let day = "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
        return sameYear ? day : "\(parts.year ?? 0) 年 \(day)"
    }
}

// MARK: - Copy and export

@MainActor
enum TranscriptActions {
    static func copy(_ record: TranscriptRecord, style: TranscriptExport.Style) {
        let text = TranscriptExport.plainText(record.paragraphs, style: style, duration: record.duration)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DiagLog.log("transcribe", "transcript copied chars=\(text.count)")
    }

    /// Save panel named after the transcript.
    static func export(_ record: TranscriptRecord, as format: TranscriptExport.Format, style: TranscriptExport.Style) {
        guard let text = TranscriptExport.render(record, as: format, style: style) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TranscriptExport.safeFileName(record.title) + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            DiagLog.log("transcribe", "exported \(format.rawValue) chars=\(text.count)")
        } catch {
            DiagLog.log("transcribe", "export failed (\(type(of: error)))")
            NSSound.beep()
        }
    }
}
