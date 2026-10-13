import Foundation

/// Icons.tsx marks used by native buttons, as SVG bodies. Stroked ones use
/// `base`'s 2-unit round stroke; filled ones fill and do not stroke.
enum WebIcon {
    private static func stroked(_ body: String) -> String {
        #"<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\#(body)</g>"#
    }
    private static func filled(_ body: String) -> String {
        #"<g fill="currentColor" stroke="none">\#(body)</g>"#
    }
    static let addSquare = stroked(#"<rect x="4" y="4" width="16" height="16" rx="3.5"/><path d="M12 8.5v7M8.5 12h7"/>"#)
    static let download = stroked(#"<path d="M12 3.5v11"/><path d="M7.5 10.5L12 15l4.5-4.5"/><path d="M4.5 19.5h15"/>"#)
    static let star = filled(#"<path d="M12 3.6l2.5 5.1 5.6.8-4 3.9 1 5.6-5.1-2.7-5.1 2.7 1-5.6-4-3.9 5.6-.8L12 3.6z"/>"#)
    static let sparkle = filled(#"<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9L12 3zM19 16l.9 2.1L22 19l-2.1.9L19 22l-.9-2.1L16 19l2.1-.9L19 16z"/>"#)
}
