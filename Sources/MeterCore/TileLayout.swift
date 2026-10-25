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

/// How tall the menu may grow before it scrolls, as a share of the screen's height.
public enum MenuHeight: String, Codable, CaseIterable, Sendable {
    /// As tall as the tiles, up to about 60% of the screen.
    case standard
    /// As tall as the tiles, up to about 85% of the screen.
    case tall
    /// Always the full height of the screen, however few tiles there are.
    case fill

    public var screenShare: Double {
        switch self {
        case .standard: 0.6
        case .tall: 0.85
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
