import Foundation

/// How much of the menu's grid a tile takes. The grid's cell is a quarter of today's tile in
/// each direction, so the full tile is 2×2 and the two smaller ones halve one side.
public enum TileSize: String, Codable, CaseIterable, Sendable {
    /// 2×2: the dial, the fullest window and up to three windows below.
    case full
    /// 2×1: full width, half height. A small dial, the fullest window and its reset.
    case short
    /// 1×2: half width, full height. Name, dial and the fullest window, stacked.
    case narrow

    public var columns: Int { self == .narrow ? 1 : 2 }
    public var rows: Int { self == .short ? 1 : 2 }

    public var title: String {
        switch self {
        case .full: "2×2 · Full"
        case .short: "2×1 · Short"
        case .narrow: "1×2 · Narrow"
        }
    }
}

/// Where a tile sits, in grid cells from the top left.
public struct TilePlacement: Equatable, Sendable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public init(column: Int, row: Int, columns: Int, rows: Int) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
    }
}

/// Places tiles of mixed sizes on a grid of `columns` columns, the way CSS grid's auto
/// placement does.
///
/// With `fillGaps` every tile takes the first free spot from the top, so a later small tile
/// moves up into a hole a bigger one left (`grid-auto-flow: dense`). Without it each tile is
/// placed after the one before it, keeping the arranged order exactly and leaving holes.
public enum TileLayout {
    public static func pack<ID: Hashable>(
        _ items: [(id: ID, size: TileSize)], columns: Int, fillGaps: Bool
    ) -> (placements: [ID: TilePlacement], rows: Int) {
        let columns = max(columns, 2)
        var occupied: [[Bool]] = []
        var placements: [ID: TilePlacement] = [:]
        var cursor = (row: 0, column: 0)

        func isFree(_ row: Int, _ column: Int, _ width: Int, _ height: Int) -> Bool {
            guard column + width <= columns else { return false }
            for r in row..<(row + height) where r < occupied.count {
                for c in column..<(column + width) where occupied[r][c] { return false }
            }
            return true
        }

        for item in items where placements[item.id] == nil {
            let width = min(item.size.columns, columns)
            let height = item.size.rows
            var row = fillGaps ? 0 : cursor.row
            var column = fillGaps ? 0 : cursor.column
            while !isFree(row, column, width, height) {
                column += 1
                if column + width > columns {
                    column = 0
                    row += 1
                }
            }
            while occupied.count < row + height { occupied.append(Array(repeating: false, count: columns)) }
            for r in row..<(row + height) {
                for c in column..<(column + width) { occupied[r][c] = true }
            }
            placements[item.id] = TilePlacement(column: column, row: row, columns: width, rows: height)
            cursor = (row, column + width)
        }
        return (placements, occupied.count)
    }
}

/// How wide the menu is: more columns of the same cells, never bigger tiles.
public enum MenuWidth: String, Codable, CaseIterable, Sendable {
    case standard, wide, wider, widest

    public var columns: Int {
        switch self {
        case .standard: 4
        case .wide: 6
        case .wider: 8
        case .widest: 10
        }
    }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .wide: "Wide"
        case .wider: "Wider"
        case .widest: "Widest"
        }
    }
}

/// How tall the menu is at least. Every choice grows with its tiles up to the same limit,
/// the screen less its header and footer, and scrolls past it; they differ in how short
/// the menu may be when there are few tiles.
public enum MenuHeight: String, Codable, CaseIterable, Sendable {
    /// As tall as the tiles, however few: how the menu has always been.
    case standard
    /// At least about 60% of the screen, so a few tiles do not leave a short menu.
    case tall
    /// Always the full height the menu may have, however few tiles there are.
    case fill

    /// The share of the screen's height the whole menu is at least.
    public var minimumShare: Double {
        switch self {
        case .standard: 0
        case .tall: 0.6
        case .fill: 1
        }
    }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .tall: "Tall"
        case .fill: "Fill the screen"
        }
    }
}

/// The menu's grid in points: cells of 84 × 80 with 8 between them, inside 10 of padding.
///
/// One place for the numbers the menu's frame, each tile's frame and the clamp to the screen
/// all have to agree about. The standard width's four columns come out at 380 pt, which is
/// the width the menu had before it could be made wider.
///
/// The screen is passed in as plain numbers: the app reads it, this file only does arithmetic.
public enum MenuGeometry {
    public static let cellWidth: CGFloat = 84
    public static let cellHeight: CGFloat = 80
    public static let gap: CGFloat = 8
    /// Between the tiles and the menu's edges.
    public static let inset: CGFloat = 10
    /// Kept free either side of the menu, so it never touches the screen's edge.
    public static let margin: CGFloat = 20
    /// The header and footer, which the tiles never use.
    public static let chrome: CGFloat = 160
    /// A menu is never shorter than this: below it a single tile is barely visible, and
    /// scrolling the tiles is better than cutting them.
    public static let minHeight: CGFloat = 240

    /// The tiles' own width at `columns` cells, before the menu's inset is added.
    public static func gridWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * cellWidth + CGFloat(max(columns - 1, 0)) * gap
    }

    /// The menu's width at `columns` cells.
    public static func width(columns: Int) -> CGFloat {
        gridWidth(columns: columns) + inset * 2
    }

    /// The menu's width as it is drawn: the chosen one, cut back to the widest this screen
    /// holds when that is narrower. A width chosen on a larger screen must not hang the
    /// menu off this one.
    public static func width(_ choice: MenuWidth, screenWidth: CGFloat) -> CGFloat {
        width(columns: columns(choice, screenWidth: screenWidth))
    }

    /// The height the tiles need at `rows` rows, which is what a menu that does not scroll is.
    public static func height(rows: Int) -> CGFloat {
        CGFloat(max(rows, 0)) * cellHeight + CGFloat(max(rows - 1, 0)) * gap
    }

    /// A tile's frame from its placement: whole cells, plus the gaps it spans.
    public static func size(_ placement: TilePlacement) -> CGSize {
        CGSize(
            width: CGFloat(placement.columns) * cellWidth + CGFloat(max(placement.columns - 1, 0)) * gap,
            height: CGFloat(placement.rows) * cellHeight + CGFloat(max(placement.rows - 1, 0)) * gap
        )
    }

    /// A tile's corner in the grid, measured from the grid's own top left.
    public static func origin(_ placement: TilePlacement) -> CGPoint {
        CGPoint(
            x: CGFloat(placement.column) * (cellWidth + gap),
            y: CGFloat(placement.row) * (cellHeight + gap)
        )
    }

    /// Whether a menu this wide fits on a screen `screenWidth` wide.
    public static func fits(_ choice: MenuWidth, screenWidth: CGFloat) -> Bool {
        width(columns: choice.columns) <= screenWidth - margin * 2
    }

    /// The columns the menu actually draws. A screen narrower than the standard menu has no
    /// narrower choice to fall back on, so standard stays and the window system places it.
    public static func columns(_ choice: MenuWidth, screenWidth: CGFloat) -> Int {
        let fitting = MenuWidth.allCases.last { fits($0, screenWidth: screenWidth) } ?? .standard
        return min(choice.columns, fitting.columns)
    }

    /// How tall the tiles may get before they scroll: the screen less the header and footer.
    /// The same for every height choice; they differ only in how short the menu may be.
    public static func maxHeight(screenHeight: CGFloat) -> CGFloat {
        max(minHeight, screenHeight - chrome)
    }

    /// How short the tile area may be: nothing for the standard height, and for the others
    /// the chosen share of the screen once the header and footer are taken out of it, never
    /// more than the most the menu may have.
    public static func minimumHeight(_ choice: MenuHeight, screenHeight: CGFloat) -> CGFloat {
        let wanted = screenHeight * choice.minimumShare - chrome
        return min(max(0, wanted), maxHeight(screenHeight: screenHeight))
    }

    /// The tile area's height for tiles that need `contentHeight`.
    public static func cardsHeight(_ choice: MenuHeight, contentHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, minimumHeight(choice, screenHeight: screenHeight)), maxHeight(screenHeight: screenHeight))
    }
}

/// Whether a window can be reached. A frame remembered on a display that has since been
/// unplugged, or rearranged, lies outside every screen: the window is "open" and nowhere to
/// be seen, and the button that opened it looks broken.
public enum WindowPlacement {
    /// A window needs enough of its top edge on some screen to be found and dragged.
    public static func isReachable(_ frame: CGRect, screens: [CGRect], minimum: CGFloat = 80) -> Bool {
        screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width >= minimum && overlap.height >= minimum
        }
    }
}
