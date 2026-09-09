//
//  ComposerCompat.swift
//  nodeloc
//
//  What the composers need in order to compile below iOS 26.
//
//  Live styling — text that looks bold while you type it — is
//  `TextEditor(text: Binding<AttributedString>, selection:)` plus
//  `AttributedTextSelection`, `transformAttributes(in:)` and
//  `selection.attributes(in:)`. All of those arrived in iOS 26 and there is no
//  SwiftUI equivalent before it. So below 26 the body field is a plain
//  `TextEditor` and the formatting buttons are hidden; everything else about
//  composing — mentions, images, GIFs, video, polls, the markdown that gets
//  sent — is unchanged, because none of it was ever attribute-based.
//
//  Nothing is lost from a draft by that: the composers already export markdown
//  run by run at submit time, and a draft loaded for editing already arrives as
//  raw markdown text rather than styled runs.
//

import SwiftUI

/// Whether the rich-text editor is available on this system.
///
/// The composers use this to decide whether to offer the formatting buttons at
/// all. It is deliberately a plain `Bool` and not an `#available` check spelled
/// out at each of the dozen call sites — one answer, one place.
enum ComposerFormatting {
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }
}

/// Holds the rich editor's selection without naming its type.
///
/// `AttributedTextSelection` is iOS 26, Swift has no conditional stored
/// properties, and a `@State` of that type in a view that compiles for 18 is an
/// error. So the value is kept type-erased in this box and cast back inside
/// `@available(iOS 26.0, *)` members, which is the one place the cast is
/// guaranteed to line up.
///
/// This is a class so that the availability-gated accessors below can be an
/// extension — an extension can't add stored properties, and the erased
/// property has to live somewhere ungated.
@Observable
final class RichSelectionBox {
    var erased: Any?

    func clear() {
        erased = nil
    }
}

@available(iOS 26.0, *)
extension RichSelectionBox {
    var selection: AttributedTextSelection {
        get { erased as? AttributedTextSelection ?? AttributedTextSelection() }
        set { erased = newValue }
    }

    /// For `TextEditor(text:selection:)`, which wants a two-way binding.
    var binding: Binding<AttributedTextSelection> {
        Binding(get: { self.selection }, set: { self.selection = $0 })
    }

    /// The caret as a character offset into `text`.
    ///
    /// A range reports its upper bound, because that is where typing would
    /// continue and a completion only cares about that end.
    func caretOffset(in text: AttributedString) -> Int? {
        let characters = text.characters
        switch selection.indices(in: text) {
        case .insertionPoint(let index):
            return characters.distance(from: characters.startIndex, to: index)
        case .ranges(let set):
            guard let last = set.ranges.last else { return nil }
            return characters.distance(from: characters.startIndex, to: last.upperBound)
        }
    }
}

extension TextSelection {
    /// The plain editor's equivalent of the above.
    ///
    /// `TextSelection` is iOS 18, so this side needs no gating at all — which is
    /// why the fallback editor can keep its selection in an ordinary `@State`
    /// and only the rich one needs the box.
    func caretOffset(in text: String) -> Int? {
        switch indices {
        case .selection(let range):
            return text.distance(from: text.startIndex, to: range.upperBound)
        case .multiSelection(let set):
            guard let last = set.ranges.last else { return nil }
            return text.distance(from: text.startIndex, to: last.upperBound)
        @unknown default:
            return nil
        }
    }
}
