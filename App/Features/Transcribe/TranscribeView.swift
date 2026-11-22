import SwiftUI
import UniformTypeIdentifiers
import ScriberCore
import ScriberShared

/// 轉錄 (pushed from 首頁): pick audio or video files with the system file importer and get
/// transcripts. Files queue up; each shows progress, the text so far and cancel. Saved
/// transcripts are listed below and open in `TranscriptDetailView`.
struct TranscribeView: View {
    var queue: TranscriptionQueue = TranscribeSource.queue
    var store: TranscriptStore = TranscribeSource.store

    @Environment(SettingsModel.self) private var settings
    @State private var options = TranscriptionOptions.load()
    @State private var showImporter = false
    @State private var keySheet: APIKeySheetItem?
    @State private var pending: [URL] = []
    @State private var openID: UUID? = TranscribeSource.initiallyOpen

    static let allowedTypes: [UTType] = [.audiovisualContent, .audio, .movie]

    private var capabilities: FileTranscriptionCapabilities { FileTranscriberFactory.capabilities(of: settings.sttProvider) }

    private var engineName: String {
        settings.sttProvider == .custom ? settings.customEngineName : settings.sttProvider.shortName
    }

    var body: some View {
        List {
            Section {
                Button {
                    showImporter = true
                } label: {
                    FullWidthLabel("選擇檔案")
                }
                .primaryActionStyle()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("音檔、影片都可以，長度不限。App 開著時轉得最順。")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            if settings.missingSTTKey != nil {
                Section {
                    Button {
                        keySheet = settings.missingSTTKey.map(APIKeySheetItem.init)
                    } label: {
                        Label("需要 \(engineName) 的 API key", systemImage: "key.fill")
                    }
                }
            }

            Section {
                Picker("語言", selection: $options.language) {
                    ForEach(TranscriptLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Toggle("時間戳", isOn: $options.timestamps)
                Toggle("說話者", isOn: Binding(get: { options.speakers && capabilities.diarization },
                                           set: { options.speakers = $0 }))
                    .disabled(!capabilities.diarization)
            } header: {
                SectionTitle("用 \(engineName) 轉錄") {
                    InfoItem(title: "時間戳", text: "每段開頭標上時間，例如 [05:07]。")
                    InfoItem(title: "說話者", text: "標出說話者 1、2…，只有 Scribe v3 做得到。整個檔案一次送出（最長 15 小時），看不到分段進度。")
                    InfoItem(title: "背景", text: "切到別的 App 後會盡量繼續；被系統暫停時，回到 Scriber 會從中斷的地方接著做，完成的部分不會重來。")
                    InfoText("不會用 AI 潤飾，只做跟聽寫一樣的整理：去贅字、套用字典、轉成繁體。")
                }
            }

            if !queue.jobs.isEmpty {
                Section("進行中") {
                    ForEach(queue.jobs) { job in
                        TranscriptionJobRow(job: job, needsKey: settings.missingSTTKey != nil,
                                            onOpen: { openID = job.transcriptID },
                                            onCancel: { queue.cancel(job) },
                                            onResume: { resume(job) },
                                            onRetryFailed: { queue.retryFailed(job) })
                            .swipeActions {
                                Button("移除", role: .destructive) { withAnimation { queue.remove(job) } }
                            }
                    }
                }
            }

            if !store.items.isEmpty {
                Section("逐字稿") {
                    ForEach(store.items) { item in
                        Button {
                            openID = item.id
                        } label: {
                            TranscriptSummaryRow(item: item)
                        }
                        .swipeActions {
                            Button("刪除", role: .destructive) {
                                store.remove(ids: [item.id])
                                Haptics.tap()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("轉錄")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: queue.jobs.map(\.id))
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .navigationDestination(item: $openID) { id in
            TranscriptDetailView(id: id, store: store, queue: queue)
        }
        .apiKeySheet(item: $keySheet)
        .onChange(of: keySheet == nil) { _, closed in
            guard closed else { return }
            settings.refreshKeys()
            let files = pending
            pending = []
            if settings.missingSTTKey == nil, !files.isEmpty { add(files) }
        }
        .onChange(of: options) { _, value in value.save() }
        .onAppear {
            store.reload()
            TranscriptionLifecycle.shared.attach(queue)
        }
    }

    private func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let missing = settings.missingSTTKey {
            pending = urls
            keySheet = APIKeySheetItem(kind: missing)
            return
        }
        var effective = options
        effective.speakers = options.speakers && capabilities.diarization
        queue.add(urls, engine: settings.sttProvider, options: effective)
        Haptics.tap()
    }

    private func resume(_ job: TranscriptionJob) {
        if let missing = settings.missingSTTKey {
            keySheet = APIKeySheetItem(kind: missing)
        } else {
            queue.resume(job)
        }
    }
}

// MARK: - Rows

/// One file in the queue: name, status, progress, the newest text, and what can be done now.
struct TranscriptionJobRow: View {
    let job: TranscriptionJob
    var needsKey = false
    var onOpen: () -> Void
    var onCancel: () -> Void
    var onResume: () -> Void
    var onRetryFailed: () -> Void

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.sourceExtension.isEmpty ? job.title : "\(job.title).\(job.sourceExtension)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(status(now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            if showsProgress {
                Group {
                    if job.phase == .preparing || (job.singleRequest && job.phase != .paused) {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: job.fraction)
                    }
                }
                .tint(.secondary)
            }
            if job.isActive, !partialTail.isEmpty {
                Text(partialTail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 54, alignment: .bottom)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black.opacity(0.25), location: 0),
                                                 .init(color: .black, location: 0.45)],
                                         startPoint: .top, endPoint: .bottom))
            }
            problems
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch job.phase {
        case .done: job.failedSegments.isEmpty ? "checkmark" : "exclamationmark"
        case .failed: "exclamationmark"
        default: Self.videoExtensions.contains(job.sourceExtension) ? "film" : "waveform"
        }
    }

    private var showsProgress: Bool {
        switch job.phase {
        case .preparing, .transcribing, .finishing, .paused: true
        default: false
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.phase {
        case .waiting, .preparing, .transcribing, .finishing:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("取消轉錄")
        case .done:
            if job.transcriptID != nil {
                Button("打開", action: onOpen)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        case .paused:
            Button("繼續", action: onResume)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        case .failed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var problems: some View {
        if case .failed(let message) = job.phase {
            HStack(alignment: .firstTextBaseline) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if job.failureKind != .file {
                    Button(job.failureKind == .settings && needsKey ? "設定 key" : "重試", action: onResume)
                        .buttonStyle(.borderless)
                        .font(.footnote.weight(.semibold))
                }
            }
        } else if job.phase == .done, !job.failedSegments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(failedSummary, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重試失敗的段落", action: onRetryFailed)
                    .buttonStyle(.borderless)
                    .font(.footnote.weight(.semibold))
            }
        } else if job.speakersUnavailable, job.phase != .cancelled {
            Text("這個檔案不分說話者（只有 Scribe v3、15 小時以內可以）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var failedSummary: String {
        let ranges = job.failedSegments.prefix(2).map {
            "\(TranscriptTime.label($0.start, longForm: job.longForm))–\(TranscriptTime.label($0.end, longForm: job.longForm))"
        }
        let more = job.failedSegments.count > 2 ? " 等" : ""
        return "\(job.failedSegments.count) 段沒有成功（\(ranges.joined(separator: "、"))\(more)）"
    }

    private var partialTail: String {
        let text = job.paragraphs.filter { !$0.isMissing }.map(\.text).joined(separator: " ")
        return text.count > 400 ? String(text.suffix(400)) : text
    }

    private func status(now: Date) -> String {
        var parts: [String] = []
        if let duration = job.duration { parts.append(TranscriptTime.duration(duration)) }
        switch job.phase {
        case .waiting: parts.append("排隊中")
        case .preparing: parts.append("讀取檔案…")
        case .transcribing:
            if job.singleRequest {
                parts.append("整段辨識中")
                if let started = job.startedAt {
                    let elapsed = now.timeIntervalSince(started)
                    parts.append("已過 \(TranscriptTime.label(elapsed, longForm: elapsed >= 3600))")
                }
            } else {
                parts.append("\(job.segmentsDone)／\(max(job.segmentsTotal, job.segmentsDone)) 段")
                if let remaining = job.estimatedRemaining { parts.append(Self.remaining(remaining)) }
            }
        case .finishing: parts.append("整理中…")
        case .done: parts.append("完成")
        case .paused: parts.append(job.autoPaused ? "已暫停，回到 App 會繼續" : "已中斷")
        case .failed: parts.append("沒有完成")
        case .cancelled: parts.append("已取消")
        }
        return parts.joined(separator: "・")
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "不到 1 分鐘" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "約 \(minutes) 分鐘" }
        return "約 \(minutes / 60) 小時 \(minutes % 60) 分"
    }
}

struct TranscriptSummaryRow: View {
    let item: TranscriptSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // Color (not the hierarchical style): inside a Button the latter resolves to the tint.
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts = [item.date.formatted(.dateTime.month().day()), TranscriptTime.duration(item.duration), item.engine.shortName]
        if item.missingCount > 0 { parts.append("\(item.missingCount) 段缺漏") }
        return parts.joined(separator: "・")
    }
}

// MARK: - Entry on 首頁

/// The row on 首頁 that opens 轉錄; shows the running file's progress when there is one.
struct TranscribeEntryRow: View {
    var queue: TranscriptionQueue = TranscribeSource.queue

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.15)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("轉錄音檔")
                    .foregroundStyle(Color.primary)
                if let line = activity {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var activity: String? {
        guard let job = queue.jobs.first(where: { $0.isActive }) else { return nil }
        if job.singleRequest || job.phase == .preparing { return "轉錄中…" }
        return "轉錄中 \(job.segmentsDone)／\(max(job.segmentsTotal, job.segmentsDone)) 段"
    }
}

/// The queue and store the screens use: the app's own, or demo data in DEBUG screenshots.
@MainActor
enum TranscribeSource {
    static var queue: TranscriptionQueue {
        #if DEBUG
        if DebugLaunch.demoData { return TranscribeDemo.shared.queue }
        #endif
        return .shared
    }

    static var store: TranscriptStore {
        #if DEBUG
        if DebugLaunch.demoData { return TranscribeDemo.shared.store }
        #endif
        return .shared
    }

    /// DEBUG `-ScriberScreen transcript` opens the first saved transcript.
    static var initiallyOpen: UUID? {
        #if DEBUG
        if DebugLaunch.screen == "transcript" { return store.items.first?.id }
        #endif
        return nil
    }
}
