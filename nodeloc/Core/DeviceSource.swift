//
//  DeviceSource.swift
//  nodeloc
//
//  What the app tells the server about the hardware a post was written on —
//  the 小尾巴 the discourse-mobile plugin renders under a post.
//

import Foundation

/// The raw hardware values `POST /posts` carries for `discourse-mobile`.
///
/// Raw, deliberately: the plugin owns the `iPhone17,1` → `iPhone 16 Pro`
/// translation, so correcting a name is an edit on the server rather than an
/// App Store release. It also means the app never has to ship a lookup table
/// that goes stale with every launch event.
///
/// Whether anything is shown at all, and how much, is the account's own
/// `mobile_post_source_level` preference (0 off … 4 model, default 4) — the
/// server reduces what it stores to the level its owner chose, so sending the
/// model is not the same as publishing it.
enum DeviceSource {
    static let platform = "ios"

    /// The plugin resolves the brand rung from the identifier ("iPhone" /
    /// "iPad") rather than printing "Apple", which would only repeat the
    /// platform rung — so this is here for completeness, not for display.
    static let brand = "Apple"

    /// The hardware identifier, e.g. `iPhone17,1`.
    ///
    /// `UIDevice.current.model` only ever answers "iPhone", and the name on the
    /// box exists in no API at all — which is exactly why the plugin translates
    /// this server-side, and why an identifier it doesn't know degrades to
    /// "iPhone" instead of being shown as a code.
    static let model: String = {
        // A simulator's `hw.machine` is the *host* architecture ("arm64"), not
        // an Apple device identifier — it would fail the plugin's identifier
        // check and get shown verbatim. The real one is in the environment.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }

        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()

    /// Form fields for a post creation request. No `marketing_name`: unlike
    /// Android, where the vendor exposes one in a system property, iOS has
    /// nothing to send — the plugin's table is the only source of a real name.
    static var postFields: [String: String] {
        var fields = [
            "mobile_source_platform": platform,
            "mobile_source_brand": brand,
        ]
        if !model.isEmpty {
            fields["mobile_source_model"] = model
        }
        return fields
    }
}
