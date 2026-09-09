//
//  ProfileSnapshot.swift
//  nodeloc
//
//  The profile page's last response, kept on disk so the next launch has
//  something to draw before the network answers.
//
//  Raw JSON rather than an encoded model, for the same reason the chat
//  snapshots are raw (`ChatRealtime`): the bytes are exactly what the server
//  sent, so there is only ever one decoding path to keep correct. Re-encoding
//  a model would add a second one that can drift from it, and a mismatch there
//  fails silently — `Codable` is all-or-nothing, and the profile models are
//  read with `try?`.
//
//  Written to Caches, not Documents. This is reconstructible from the network
//  by definition, so it should be the first thing the system reclaims under
//  pressure and it has no business in a backup.
//

import Foundation

enum ProfileSnapshot {
    /// One file, for whoever is signed in — not one per username.
    ///
    /// Keyed by username it was unreachable exactly when it was needed most:
    /// on a cold launch the username can still be unknown (it comes from the
    /// Keychain, or from the server when that is empty), so the page had no
    /// name to look a snapshot up by and drew placeholders instead of the
    /// cache. There is only ever one signed-in account, and signing out
    /// deletes this, so a name in the path bought nothing.
    private static func fileURL() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }

        let directory = caches.appending(path: "profile-snapshots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "me.json")
    }

    static func save(_ data: Data) {
        guard let url = fileURL() else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> Data? {
        guard let url = fileURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Dropped on sign-out: the next reader of this device must not be shown
    /// the last one's profile while their own loads.
    static func clearAll() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        try? FileManager.default.removeItem(
            at: caches.appending(path: "profile-snapshots", directoryHint: .isDirectory)
        )
    }
}
