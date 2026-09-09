//
//  NetworkReachability.swift
//  nodeloc
//
//  Whether the device has a network path, so the chat outbox can send itself
//  when one comes back.
//
//  Without this, a message written in a dead spot waited for the reader to
//  reopen the conversation — the queue was durable but only drained on an
//  action the reader had no reason to take. "It'll go when you're back online"
//  is the part that makes a queue feel like a messenger rather than a retry
//  button.
//
//  Deliberately not used to *block* anything. `isOnline` starts true and stays
//  true until the system says otherwise, because a wrong "offline" that
//  refuses to even attempt a send is worse than a failed attempt: the attempt
//  is what produces the real error, and NWPathMonitor's view of a captive
//  portal or a VPN coming up is not always the truth.
//

import Foundation
import Network

@MainActor
@Observable
final class NetworkReachability {
    static let shared = NetworkReachability()

    /// Optimistic until told otherwise — see the note above.
    private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.apply(isOnline: satisfied)
            }
        }
        // Not the main queue: path updates arrive during launch and while
        // scrolling, and this has nothing to do on the main thread until the
        // value actually changes.
        monitor.start(queue: DispatchQueue(label: "com.nodeloc.reachability", qos: .utility))
    }

    private func apply(isOnline newValue: Bool) {
        // Only real transitions, so observers aren't woken by every repeated
        // report of the same state — the monitor sends those freely.
        guard newValue != isOnline else { return }
        isOnline = newValue
    }
}
