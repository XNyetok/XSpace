import CoreGraphics

/// The zoom of the page in a pane (WKWebView.pageZoom), in percent. Pages are made for browser
/// windows: in a smaller pane they are zoomed out, so that they are laid out for the width of a
/// window instead of switching to their layout for phones (at 70%, a pane 700 points wide gives the
/// page 1000 pixels). The profile's own zoom (⌘+ / ⌘−) comes on top.
enum PageZoom {
    /// A page area at least this big (in points) shows its page at 100%: about a small browser
    /// window, where most sites show their layout for computers.
    static let fullSize = CGSize(width: 1024, height: 640)
    /// The smallest automatic zoom: 14-pixel text stays about 10 points tall.
    static let minimumAutomatic = 70
    /// What ⌘+ and ⌘− add or take away, in percentage points.
    static let step = 10
    /// The zooms a page can have.
    static let range = 30...300

    /// The automatic zoom of a page area of `size`: the share of `fullSize` that fits, rounded down
    /// to 5% (so that the page is not laid out again for every small change), from
    /// `minimumAutomatic` to 100.
    static func automatic(for size: CGSize) -> Int {
        let fit = min(1, size.width / fullSize.width, size.height / fullSize.height)
        guard fit > 0 else { return minimumAutomatic }
        // The small addition keeps a share of exactly 0.95 from becoming 94.99… and then 90.
        let percent = Int((fit * 100 + 1e-6).rounded(.down))
        return max(minimumAutomatic, percent - percent % 5)
    }

    /// The zoom shown: `base` (the automatic zoom, or 100) plus the profile's own `offset`, within
    /// `range`.
    static func zoom(base: Int, offset: Int) -> Int {
        // A hand-edited state.json can hold any number: the sum must not overflow.
        let offset = min(max(offset, -range.upperBound), range.upperBound)
        return min(range.upperBound, max(range.lowerBound, base + offset))
    }

    /// The profile's own zoom after ⌘+ (`points` above 0) or ⌘− (below 0): the zoom shown changes
    /// by `points`, within `range`.
    static func offset(_ offset: Int, base: Int, adding points: Int) -> Int {
        zoom(base: zoom(base: base, offset: offset), offset: points) - base
    }
}
