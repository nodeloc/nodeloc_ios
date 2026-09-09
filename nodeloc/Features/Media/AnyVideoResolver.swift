//
//  AnyVideoResolver.swift
//  nodeloc
//
//  Turns a cooked video placeholder into a URL AVPlayer can actually play.
//

import Foundation

/// Resolves a post's video to its HLS rendition, falling back to the original
/// upload.
///
/// The HLS stream is what the web player uses — `by_sha1` is the same lookup its
/// JS makes — and it is adaptive rather than one big progressive file.
///
/// It is also the *only* one that plays. Measured 2026-09-02 across four
/// videos taken from `anyvideo/videos/suggestions.json`: every
/// `data-video-src` original answered **404**, every corresponding
/// `master.m3u8` answered 200/206 and walked cleanly down to its segments. So
/// the site does stop serving originals once they are transcoded, and an
/// earlier note here arguing they were "still served, just intermittent" was
/// wrong.
///
/// The original stays as the fallback anyway, because `by_sha1` is a Rails
/// endpoint that can answer 503 when the site is busy — but treat it as a
/// last resort that will probably 404, not as a working path. Anything that
/// hands a raw upload URL straight to AVPlayer is a bug.
///
/// If playback looks soft, it is not this class: the plugin's `master.m3u8`
/// ships no `RESOLUTION` or `CODECS` (AVFoundation reports every variant as
/// `presentationSize` 0x0), and its top rendition is a quarter of the source's
/// pixels. Both are server-side; measurements and the fix are in
/// `SERVER_TASKS_VIDEO.md`. There is no AVFoundation API to bias variant
/// selection upward, so don't go looking for one.
///
/// Resolutions are cached for the session: the pager tears a page's player down
/// and rebuilds it every time it scrolls past, and that shouldn't re-ask.
@MainActor
@Observable
final class AnyVideoResolver {
    static let shared = AnyVideoResolver()

    private let client = DiscourseClient()
    private var cached: [String: AnyVideoResponse] = [:]
    private var inFlight: [String: Task<AnyVideoResponse?, Never>] = [:]

    private init() {}

    /// Same, for callers that only carry the upload URL — the feed's cards, and
    /// chat, whose videos arrive on `uploads` and never had a cooked
    /// placeholder to read a sha1 out of.
    func playableURL(forUpload url: URL) async -> URL? {
        await playableURL(for: PostVideo(src: url.absoluteString))
    }

    /// The URL to hand a player, or nil when the video can't be played at all.
    func playableURL(for video: PostVideo) async -> URL? {
        let fallback = PostInlineRenderer.resolvedLink(video.src)
        guard let sha1 = video.sha1 else { return fallback }
        guard let response = await lookup(sha1),
              response.isReady,
              let hls = response.hlsUrl,
              let url = nodelocSiteURL(hls)
        else { return fallback }
        return url
    }

    /// The poster the plugin wrote alongside the renditions, for surfaces that
    /// draw a tile before anything plays.
    ///
    /// Nil while a transcode is still pending: `thumbnail_url` comes back null
    /// until it finishes, which is also why there is nothing to fall back to —
    /// the original upload is already gone by then.
    func posterURL(forUpload url: URL) async -> URL? {
        guard let sha1 = PostVideo(src: url.absoluteString).sha1,
              let thumbnail = await lookup(sha1)?.thumbnailUrl
        else { return nil }
        return nodelocSiteURL(thumbnail)
    }

    /// One `by_sha1` per video, shared by the poster and the stream — a tile
    /// that then gets played should not ask twice.
    private func lookup(_ sha1: String) async -> AnyVideoResponse? {
        if let hit = cached[sha1] { return hit }

        let task = inFlight[sha1] ?? Task { [client] in
            try? await client.anyVideo(sha1: sha1)
        }
        inFlight[sha1] = task
        let response = await task.value
        inFlight[sha1] = nil

        // Only a finished transcode is cached; one still running should be
        // asked about again next time.
        if let response, response.isReady { cached[sha1] = response }
        return response
    }
}
