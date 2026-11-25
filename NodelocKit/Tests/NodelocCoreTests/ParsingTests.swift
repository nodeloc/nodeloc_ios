import Foundation
import XCTest
@testable import NodelocCore

final class ParsingTests: XCTestCase {
    // MARK: Dates

    func testGoTimesNormalizeToUTCMilliseconds() {
        XCTAssertEqual(NLDate.normalize("2026-11-25T01:33:46.723291+08:00"), "2026-11-24T17:33:46.723Z")
        XCTAssertEqual(NLDate.normalize("2026-11-25T01:33:46Z"), "2026-11-25T01:33:46.000Z")
        XCTAssertEqual(NLDate.normalize("2026-11-25T01:33:46.1-05:30"), "2026-11-25T07:03:46.100Z")
        XCTAssertEqual(NLDate.normalize("not a date"), "not a date")
        XCTAssertNil(NLDate.normalize(nil))
    }

    @MainActor
    func testNormalizedTimesParseWithTheAppsParser() async {
        let normalized = NLDate.normalize("2026-11-25T01:33:46.723291+08:00")
        XCTAssertNotNil(DiscourseFormat.date(normalized))
    }

    // MARK: Server-sent events

    func testSSEParserHandlesSplitChunksAndComments() {
        var parser = SSEParser()
        let stream = "event: unread\ndata: {\"unread\":3}\n\n: ping\n\nevent: chat\r\ndata: {\"type\":\"new\",\r\ndata: \"conversation\":4}\r\n\r\n"
        let bytes = Array(stream.utf8)
        var events: [SSEEvent] = []
        // One byte at a time: the worst a network can do.
        for byte in bytes { events += parser.feed(Data([byte])) }
        XCTAssertEqual(events, [
            SSEEvent(event: "unread", data: "{\"unread\":3}"),
            SSEEvent(event: "chat", data: "{\"type\":\"new\",\n\"conversation\":4}"),
        ])
    }

    func testSSEParserKeepsMultibyteTextAcrossChunks() {
        var parser = SSEParser()
        let bytes = Array("data: 你好\n\n".utf8)
        var events = parser.feed(Data(bytes[0..<7]))
        events += parser.feed(Data(bytes[7...]))
        XCTAssertEqual(events.first?.data, "你好")
        XCTAssertEqual(events.first?.event, "message")
    }

    @MainActor
    func testChatEventsRouteToTheirSubscriptions() async {
        let subscribed = ["/chat/4/new-messages", "/chat/5/new-messages", "/chat/4"]
        let new = NLStreamChatEvent(type: "new", conversation: 4, kind: "direct", message: 10, sender: 2,
                                    senderName: "bob", joined: nil, left: nil, kicked: nil, system: nil, muted: nil, mentioned: nil)
        XCTAssertEqual(Set(MessageBusClient.channels(for: new, among: subscribed)), ["/chat/4/new-messages", "/chat/4"])
        let resync = NLStreamChatEvent(type: "resync", conversation: nil, kind: nil, message: nil, sender: nil,
                                       senderName: nil, joined: nil, left: nil, kicked: nil, system: nil, muted: nil, mentioned: nil)
        XCTAssertEqual(MessageBusClient.channels(for: resync, among: subscribed).count, 3)
    }

    // MARK: Post markup

    @MainActor
    func testBackendMarkupParsesIntoTheReadersBlocks() async {
        let html = """
        <p>Intro <a class="mention" href="/u/Alice" data-hc="user:Alice">@Alice</a> \
        <a class="mention mn-tag" href="/tag/go" data-hc="tag:go">#go</a> \
        <a class="mention mn-node" href="/n/indie" data-hc="node:indie" data-ref="$indie" title="独立开发"><span class="mn-av" data-letter="独" style="background:#007A52" aria-hidden="true"></span>n/indie</a></p>
        <div class="poll" data-poll="p1"><ul><li>a</li><li>b</li></ul></div>
        <div class="video-embed" data-provider="upload" data-video-id="0123456789abcdef0123456789abcdef01234567"></div>
        <div class="spoiler post-spoiler" data-spoiler tabindex="0">
        <p>secret</p>
        </div>
        <div class="hidden-block" data-hidden="1" data-kind="login" data-amount="0">这部分内容登录后可见</div>
        <details class="post-details"><summary>标题</summary>
        <p>inside</p>
        </details>
        """
        let cooked = NodelocMarkup.cooked(html)
        XCTAssertTrue(cooked.contains(#"data-poll-name="p1""#))
        XCTAssertTrue(cooked.contains("video-placeholder-container"))
        XCTAssertTrue(cooked.contains("permission-login-placeholder"))
        XCTAssertTrue(cooked.contains(#"<a class="hashtag-cooked" href="/c/indie" data-type="category" data-slug="indie">独立开发</a>"#))

        let content = PostHTMLParser.parseSync(cooked)
        let description = String(describing: content)
        XCTAssertTrue(description.contains("pollPlaceholder"), description)
        XCTAssertTrue(description.contains("0123456789abcdef0123456789abcdef01234567"))
        XCTAssertTrue(description.contains("spoiler"))
        XCTAssertTrue(description.contains("permission"))
        XCTAssertTrue(description.contains("indie"))
    }

    func testYouTubeAndBilibiliEmbeds() {
        let youtube = NodelocMarkup.cooked(#"<div class="video-embed" data-provider="youtube" data-video-id="dQw4w9WgXcQ"><a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">x</a></div>"#)
        XCTAssertTrue(youtube.contains("lazy-video-container"))
        let bilibili = NodelocMarkup.cooked(#"<div class="video-embed" data-provider="bilibili" data-video-id="BV1xx"><a href="https://www.bilibili.com/video/BV1xx">x</a></div>"#)
        XCTAssertTrue(bilibili.hasPrefix("<iframe"))
        XCTAssertTrue(bilibili.contains("bvid=BV1xx"))
    }

    func testFirstImageSkipsEmoji() {
        let html = #"<p><img class="emoji em-img" src="/e.png" alt=":x:"> <img src="/uploads/original/ab/c.png" alt="c" width="400" height="250"></p>"#
        let image = NodelocMarkup.firstImage(in: html)
        XCTAssertEqual(image?.url, "/uploads/original/ab/c.png")
        XCTAssertEqual(image?.width, 400)
    }

    // MARK: Errors and credentials

    func testErrorEnvelopePrefersFieldMessages() {
        let body = Data(#"{"error":{"code":"invalid","message":"输入有误","fields":{"title":"标题太短"}}}"#.utf8)
        let envelope = NodelocHTTP.errorEnvelope(from: body)
        XCTAssertEqual(envelope.code, "invalid")
        XCTAssertEqual(envelope.message, "标题太短")
    }

    func testCredentialEncodingRoundTrips() {
        for credential in [NodelocCredential.bearer("abc"), .cookie("xyz")] {
            XCTAssertEqual(NodelocCredential(encoded: credential.encoded), credential)
        }
        XCTAssertNil(NodelocCredential(encoded: "garbage"))
    }

    func testBase64URL() {
        let data = Data([0xfb, 0xff, 0x00, 0x10])
        XCTAssertEqual(Base64URL.encode(data), "-_8AEA")
        XCTAssertEqual(Base64URL.decode("-_8AEA"), data)
    }

    // MARK: PKCE

    func testSHA256Vectors() {
        let hex = { (bytes: [UInt8]) in bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(PortableSHA256.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(PortableSHA256.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Spans several 64-byte blocks.
        XCTAssertEqual(hex(PortableSHA256.hash(Array(repeating: UInt8(ascii: "a"), count: 1000))),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPKCEChallengeIsBase64URLOfSHA256() {
        XCTAssertEqual(NodelocPKCE.challenge(for: "dBjftJeZ4CVP-mJ0kZ-BLv3uTQ_3pv4FdmUaB09dq9k"),
                       "I2R7jBXcnLdP68dWOXzraygRE-sH5yO8hprhCFA3BRk")
        let pair = NodelocPKCE.make()
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge, NodelocPKCE.challenge(for: pair.verifier))
        XCTAssertNotEqual(pair.verifier, NodelocPKCE.make().verifier)
    }

    @MainActor
    func testSocialCallbackParsing() async throws {
        XCTAssertEqual(try DiscourseLogin.socialCallback(URL(string: "nodeloc://auth?code=abc123")!), "abc123")
        XCTAssertThrowsError(try DiscourseLogin.socialCallback(URL(string: "nodeloc://auth?error=cancelled")!)) { error in
            guard case AuthError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try DiscourseLogin.socialCallback(URL(string: "nodeloc://auth")!))
    }

    @MainActor
    func testSocialSignInURLCarriesAppAndChallenge() async throws {
        let login = DiscourseLogin(auth: DiscourseAuth(), baseURL: URL(string: "https://www.nodeloc.com")!, store: DefaultCredentialStore())
        let pkce = NodelocPKCE(verifier: "v", challenge: "c")
        let url = login.socialSignInURL(provider: "github", pkce: pkce)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/auth/github")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["app"], "ios")
        XCTAssertEqual(query["redirect_uri"], "nodeloc://auth")
        XCTAssertEqual(query["code_challenge"], "c")
        XCTAssertEqual(login.socialSignInURL(provider: nil, pkce: pkce).path, "/login")
    }
}
