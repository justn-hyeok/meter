import Testing
@testable import MeterCore

private func place(_ sizes: [TileSize], columns: Int = 4, fillGaps: Bool) -> ([TilePlacement], Int) {
    let items = sizes.enumerated().map { (id: $0.offset, size: $0.element) }
    let result = TileLayout.pack(items, columns: columns, fillGaps: fillGaps)
    return (sizes.indices.map { result.placements[$0]! }, result.rows)
}

@Test func fullTilesSitTwoToARowOnTheStandardWidth() {
    let (placed, rows) = place([.full, .full, .full], fillGaps: true)
    #expect(placed.map(\.column) == [0, 2, 0])
    #expect(placed.map(\.row) == [0, 0, 2])
    #expect(rows == 4)
}

/// The board's case A: a narrow tile moves up into the hole beside an earlier one.
@Test func fillingGapsMovesALaterTileUp() {
    let sizes: [TileSize] = [.short, .narrow, .short, .narrow, .short]
    let (dense, denseRows) = place(sizes, fillGaps: true)
    #expect(dense[3] == TilePlacement(column: 3, row: 0, columns: 1, rows: 2))
    #expect(denseRows == 3)

    // Case B: kept in order, the same tile goes after the one before it, leaving a hole.
    let (sparse, _) = place(sizes, fillGaps: false)
    #expect(sparse[3].row > sparse[2].row || (sparse[3].row == sparse[2].row && sparse[3].column > sparse[2].column))
    #expect(sparse[3] != dense[3])
}

@Test func widerMenusTakeMoreTilesPerRow() {
    let (placed, rows) = place(Array(repeating: .full, count: 5), columns: 10, fillGaps: true)
    #expect(placed.map(\.row) == [0, 0, 0, 0, 0])
    #expect(rows == 2)
    #expect(MenuWidth.allCases.map(\.columns) == [4, 6, 8, 10])
}

@Test func tileSizesSpanTheirCells() {
    #expect((TileSize.full.columns, TileSize.full.rows) == (2, 2))
    #expect((TileSize.short.columns, TileSize.short.rows) == (2, 1))
    #expect((TileSize.narrow.columns, TileSize.narrow.rows) == (1, 2))
}
