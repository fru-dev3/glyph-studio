import SwiftUI

/// The reading column grows with the window: 700 wide (the renders) up to 1100x700, then 66% of the
/// place beside the rail, up to 1040. Bubbles, cards and sheets scale from it.
extension EnvironmentValues {
    @Entry var column: CGFloat = 700
}

struct ColumnFrame: ViewModifier {
    @Environment(\.column) private var column
    var share: CGFloat, fixed: Bool, height: CGFloat?, alignment: Alignment
    func body(content: Content) -> some View {
        if fixed { content.frame(width: column * share, height: height, alignment: alignment) }
        else { content.frame(maxWidth: column * share, alignment: alignment) }
    }
}

extension View {
    /// Exactly the column (or a share of it).
    func column(_ share: CGFloat = 1, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ColumnFrame(share: share, fixed: true, height: height, alignment: alignment))
    }
    /// At most a share of the column.
    func columnMax(_ share: CGFloat, alignment: Alignment = .leading) -> some View {
        modifier(ColumnFrame(share: share, fixed: false, height: nil, alignment: alignment))
    }
}
