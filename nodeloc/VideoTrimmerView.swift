//
//  VideoTrimmerView.swift
//  nodeloc
//
//  The composer's video preview tile and its full-screen trimmer: filmstrip
//  timeline, draggable in/out handles, looping preview, and a GIF toggle.
//
//  Like the image editor, edits are non-destructive: the trimmer only mutates a
//  `VideoEditPlan`, and the export runs once on commit. An untrimmed, non-GIF
//  plan skips the export entirely and uploads the original file.
//

import AVFoundation
import AVKit
import SwiftUI

// MARK: - Composer tile

/// The in-post video preview: poster frame, play affordance, delete badge.
struct ComposeVideoTile: View {
    let attachment: ComposeVideoAttachment
    let onTap: () -> Void
    let onDelete: () -> Void
    let onRetry: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        return poster
            .filledBanner(height: 190, clip: shape)
            .overlay { shape.strokeBorder(Theme.divider, lineWidth: 1) }
            .overlay { centerBadge }
            .overlay(alignment: .bottomLeading) { durationChip }
            .contentShape(shape)
            .onTapGesture {
                if case .failed = attachment.upload {
                    onRetry()
                } else {
                    onTap()
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.62), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            // Headroom so the badge isn't clipped by the surrounding stack.
            .padding(.top, 2)
    }

    @ViewBuilder
    private var poster: some View {
        if let data = attachment.posterData, let image = UIImage(data: data) {
            // `filledBanner` applies `scaledToFill`.
            Image(uiImage: image).resizable()
        } else {
            Theme.hover
        }
    }

    @ViewBuilder
    private var centerBadge: some View {
        switch attachment.upload {
        case .pending, .uploading:
            ZStack {
                Color.black.opacity(0.28)
                ProgressView().tint(.white)
            }
        case .failed:
            ZStack {
                Color.black.opacity(0.44)
                VStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .bold))
                    Text("重试")
                        .font(Theme.body(12, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
        case .ready:
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Color.black.opacity(0.42), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
        }
    }

    @ViewBuilder
    private var durationChip: some View {
        if case .ready = attachment.upload {
            HStack(spacing: 4) {
                if attachment.plan.asGIF {
                    Text("GIF")
                        .font(Theme.body(10, weight: .heavy))
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(VideoTimeFormat.short(attachment.plan.trimmedDuration))
                        .font(Theme.body(11, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(10)
        }
    }
}

enum VideoTimeFormat {
    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0.0s" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

// MARK: - Trimmer state

@MainActor
@Observable
final class VideoTrimmerState {
    var plan: VideoEditPlan
    private(set) var frames: [CGImage] = []
    private(set) var isLoadingFrames = true
    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0
    var errorText: String?
    var isPlaying = false
    /// Playhead in seconds, driven by the player's periodic observer.
    var currentTime: Double = 0

    let player: AVPlayer
    private let sourceURL: URL
    private var timeObserver: Any?

    init(attachment: ComposeVideoAttachment) {
        self.sourceURL = attachment.sourceURL
        self.plan = attachment.plan
        self.player = AVPlayer(url: attachment.sourceURL)
        self.player.isMuted = false
    }

    var duration: Double { max(plan.duration, 0.01) }

    /// GIF output is capped, so the UI can warn when a longer range is trimmed down.
    var gifWouldClamp: Bool {
        plan.asGIF && plan.trimmedDuration > VideoExporter.gifMaxSeconds
    }

    func load() async {
        // Start the playhead at the trim start rather than 0.
        await seek(to: plan.startSeconds)
        installObserver()
        frames = await VideoExporter.filmstrip(for: sourceURL, duration: duration)
        isLoadingFrames = false
    }

    func tearDown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
    }

    /// Keeps playback inside the trim window and loops it.
    private func installObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                let seconds = CMTimeGetSeconds(time)
                self.currentTime = seconds
                if seconds >= self.plan.endSeconds - 0.02 {
                    Task { await self.seek(to: self.plan.startSeconds) }
                }
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // Restart from the trim start when the playhead sits outside it.
            if currentTime < plan.startSeconds || currentTime >= plan.endSeconds - 0.02 {
                Task { await seek(to: plan.startSeconds) }
            }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) async {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        await player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Outcome of a commit. Distinguishing "nothing to re-encode" from "the
    /// export failed" matters: the first commits and closes, the second has to
    /// keep the trimmer open.
    enum ExportOutcome {
        /// Untrimmed and not a GIF — the composer keeps the original file.
        case unchanged
        case exported(URL)
        case failed
    }

    func export() async -> ExportOutcome {
        guard !plan.isIdentity else { return .unchanged }

        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        do {
            let url = plan.asGIF
                ? try await VideoExporter.exportGIF(source: sourceURL, plan: plan)
                : try await VideoExporter.exportTrimmed(source: sourceURL, plan: plan)
            // exportTrimmed returns nil only for an identity plan, already
            // handled above.
            guard let url else { return .unchanged }
            return .exported(url)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed
        }
    }
}

// MARK: - Trimmer view

struct VideoTrimmerView: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: ComposeVideoAttachment
    /// Hands back the updated plan and, when an export ran, the new file URL.
    let onCommit: (VideoEditPlan, URL?) -> Void

    @State private var state: VideoTrimmerState
    /// Which handle a drag grabbed, classified on first change.
    @State private var dragTarget: TrimDragTarget = .none

    private enum TrimDragTarget { case none, start, end }

    private let trackHeight: CGFloat = 56
    private let handleWidth: CGFloat = 14
    /// Never let the window shrink below this.
    private let minTrimSeconds: Double = 0.5

    init(
        attachment: ComposeVideoAttachment,
        onCommit: @escaping (VideoEditPlan, URL?) -> Void
    ) {
        self.attachment = attachment
        self.onCommit = onCommit
        _state = State(initialValue: VideoTrimmerState(attachment: attachment))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("调整剪辑")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 14)

                playerArea

                gifToggle

                timeline

                bottomBar
            }
        }
        .task { await state.load() }
        .onDisappear { state.tearDown() }
        .statusBarHidden()
        .alert(
            state.errorText ?? "",
            isPresented: Binding(
                get: { state.errorText != nil },
                set: { if !$0 { state.errorText = nil } }
            )
        ) {
            Button("好", role: .cancel) { state.errorText = nil }
        }
    }

    // MARK: Player

    private var playerArea: some View {
        VideoPlayer(player: state.player)
            .disabled(true)
            .aspectRatio(playerAspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .onTapGesture { state.togglePlayback() }
    }

    private var playerAspect: CGFloat {
        let size = attachment.pixelSize
        guard size.width > 0, size.height > 0 else { return 9.0 / 16.0 }
        return size.width / size.height
    }

    // MARK: GIF toggle

    private var gifToggle: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("GIF")
                    .font(Theme.body(11, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white, in: Capsule())

                Text("以 GIF 的形式发布")
                    .font(Theme.body(15))
                    .foregroundStyle(.white)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { state.plan.asGIF },
                    set: { state.plan.asGIF = $0 }
                ))
                .labelsHidden()
                .tint(Color(hex: 0x1B6BFF))
            }

            if state.gifWouldClamp {
                Text("GIF 最长 \(Int(VideoExporter.gifMaxSeconds)) 秒，超出部分会被截断。")
                    .font(Theme.body(11))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let startX = position(for: state.plan.startSeconds, width: width)
                let endX = position(for: state.plan.endSeconds, width: width)

                ZStack(alignment: .leading) {
                    filmstrip

                    // Dim outside the selection.
                    Color.black.opacity(0.55)
                        .frame(width: max(0, startX))
                        .frame(maxHeight: .infinity, alignment: .leading)
                    Color.black.opacity(0.55)
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)
                        .frame(maxHeight: .infinity, alignment: .leading)

                    // Selection border + handles.
                    selectionOverlay(startX: startX, endX: endX)

                    // Playhead.
                    if state.isPlaying {
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2)
                            .offset(x: position(for: state.currentTime, width: width) - 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(timelineGesture(width: width))
            }
            .frame(height: trackHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack {
                Text(VideoTimeFormat.short(state.plan.startSeconds))
                Spacer()
                Text(VideoTimeFormat.short(state.plan.endSeconds))
            }
            .font(Theme.body(11))
            .foregroundStyle(.white.opacity(0.6))
            .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            if state.isLoadingFrames {
                Color.white.opacity(0.08)
            } else {
                ForEach(Array(state.frames.enumerated()), id: \.offset) { _, frame in
                    Image(uiImage: UIImage(cgImage: frame))
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectionOverlay(startX: CGFloat, endX: CGFloat) -> some View {
        let width = max(0, endX - startX)
        return ZStack(alignment: .leading) {
            Rectangle()
                .strokeBorder(Color(hex: 0xF5C518), lineWidth: 3)
                .frame(width: width)
                .offset(x: startX)

            handle(at: startX - handleWidth / 2)
            handle(at: endX - handleWidth / 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handle(at x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(hex: 0xF5C518))
            .frame(width: handleWidth)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.black.opacity(0.45))
                    .frame(width: 2, height: 16)
            }
            .offset(x: x)
    }

    private func position(for seconds: Double, width: CGFloat) -> CGFloat {
        guard state.duration > 0 else { return 0 }
        return CGFloat(seconds / state.duration) * width
    }

    private func seconds(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width) * state.duration, 0), state.duration)
    }

    /// One gesture for the whole track; the grabbed handle is classified on the
    /// first change so the two handles can't fight over overlapping hit areas.
    private func timelineGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragTarget == .none {
                    let startX = position(for: state.plan.startSeconds, width: width)
                    let endX = position(for: state.plan.endSeconds, width: width)
                    // Whichever handle is nearer the touch wins.
                    dragTarget = abs(value.startLocation.x - startX) <= abs(value.startLocation.x - endX)
                        ? .start
                        : .end
                    state.pause()
                }

                let target = seconds(atX: value.location.x, width: width)
                switch dragTarget {
                case .start:
                    state.plan.startSeconds = min(target, state.plan.endSeconds - minTrimSeconds)
                    state.plan.startSeconds = max(0, state.plan.startSeconds)
                    Task { await state.seek(to: state.plan.startSeconds) }
                case .end:
                    state.plan.endSeconds = max(target, state.plan.startSeconds + minTrimSeconds)
                    state.plan.endSeconds = min(state.duration, state.plan.endSeconds)
                    Task { await state.seek(to: state.plan.endSeconds) }
                case .none:
                    break
                }
            }
            .onEnded { _ in
                dragTarget = .none
                Task { await state.seek(to: state.plan.startSeconds) }
            }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button("返回") { dismiss() }
                .font(Theme.body(15))
                .foregroundStyle(.white)
                .buttonStyle(.plain)

            Spacer()

            Button {
                state.togglePlayback()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                commit()
            } label: {
                Group {
                    if state.isExporting {
                        ProgressView().tint(.white)
                    } else {
                        Text("下一步")
                            .font(Theme.body(15, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(state.isExporting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
        }
    }

    private func commit() {
        state.pause()
        Task {
            switch await state.export() {
            case .failed:
                // Stay open so the user can retry or back out; the error alert
                // is already showing.
                return
            case .unchanged:
                onCommit(state.plan, nil)
            case .exported(let url):
                onCommit(state.plan, url)
            }
            dismiss()
        }
    }
}

// MARK: - Previews

#Preview("剪辑器") {
    let attachment = ComposeVideoAttachment(
        sourceURL: URL(fileURLWithPath: "/tmp/preview.mp4"),
        pixelSize: CGSize(width: 1080, height: 1920),
        duration: 5.3,
        fileName: "clip.mp4",
        mimeType: "video/mp4"
    )
    return VideoTrimmerView(attachment: attachment) { _, _ in }
}

#Preview("视频预览卡片") {
    var ready = ComposeVideoAttachment(
        sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"),
        pixelSize: CGSize(width: 1080, height: 1920),
        duration: 5.3,
        fileName: "clip.mp4",
        mimeType: "video/mp4"
    )
    ready.upload = .ready("upload://abc.mp4")

    return VStack(spacing: 16) {
        ComposeVideoTile(attachment: ready, onTap: {}, onDelete: {}, onRetry: {})
    }
    .padding(20)
    .background(Theme.bg)
}
