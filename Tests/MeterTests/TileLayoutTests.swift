import CoreGraphics
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

/// Every 2×2 tile on the standard width must stay the 176 × 168 the menu has always drawn,
/// and the menu itself the 380 it has always been.
@Test func theStandardWidthKeepsTheMenuAndItsTilesTheirOldSize() {
    #expect(MenuGeometry.width(columns: MenuWidth.standard.columns) == 380)
    // The grid sits inside the menu's inset on both sides, so the two add up to the menu.
    for width in MenuWidth.allCases {
        #expect(MenuGeometry.gridWidth(columns: width.columns) + MenuGeometry.inset * 2 == MenuGeometry.width(columns: width.columns))
    }
    #expect(MenuGeometry.gridWidth(columns: MenuWidth.standard.columns) == 360)
    #expect(MenuGeometry.width(.standard, screenWidth: 1_440) == 380)
    #expect(MenuWidth.allCases.map { MenuGeometry.width(columns: $0.columns) } == [380, 564, 748, 932])
    #expect(MenuGeometry.size(TilePlacement(column: 0, row: 0, columns: 2, rows: 2)) == CGSize(width: 176, height: 168))
}

@Test func aTileSpansItsCellsAndTheGapsBetweenThem() {
    #expect(MenuGeometry.size(TilePlacement(column: 2, row: 0, columns: 2, rows: 1)) == CGSize(width: 176, height: 80))
    #expect(MenuGeometry.size(TilePlacement(column: 3, row: 2, columns: 1, rows: 2)) == CGSize(width: 84, height: 168))
    #expect(MenuGeometry.origin(TilePlacement(column: 2, row: 1, columns: 2, rows: 2)) == CGPoint(x: 184, y: 88))
    #expect(MenuGeometry.height(rows: 0) == 0)
    // Two full rows: the height of two tiles plus the gap between them.
    #expect(MenuGeometry.height(rows: 4) == 344)
}

@Test func aMenuWiderThanTheScreenIsCutBackToTheWidestThatFits() {
    // The widest menu, 932, plus the margin either side, needs a 972 point screen.
    #expect(MenuGeometry.fits(.widest, screenWidth: 972))
    #expect(!MenuGeometry.fits(.widest, screenWidth: 971))

    #expect(MenuGeometry.columns(.widest, screenWidth: 1_440) == 10)
    #expect(MenuGeometry.columns(.widest, screenWidth: 972) == 10)
    #expect(MenuGeometry.columns(.widest, screenWidth: 800) == 8)
    #expect(MenuGeometry.columns(.widest, screenWidth: 700) == 6)
    // A width chosen for a narrow choice stays narrow on a wide screen.
    #expect(MenuGeometry.columns(.standard, screenWidth: 1_440) == 4)
    // Narrower than the standard menu there is no narrower choice to fall back on.
    #expect(MenuGeometry.columns(.widest, screenWidth: 300) == 4)
    #expect(MenuGeometry.width(.widest, screenWidth: 800) == 748)
}

@Test func everyMenuHeightGrowsToTheSameLimitAndDiffersInHowShortItMayBe() {
    // A 1,000 pt screen: tiles may use up to 840 pt, as they always could.
    #expect(MenuGeometry.maxHeight(screenHeight: 1_000) == 840)
    #expect(MenuGeometry.maxHeight(screenHeight: 300) == 240)

    func cards(_ choice: MenuHeight, content: CGFloat) -> CGFloat {
        MenuGeometry.cardsHeight(choice, contentHeight: content, screenHeight: 1_000)
    }
    // Standard hugs the tiles, exactly as before.
    #expect(cards(.standard, content: 300) == 300)
    #expect(cards(.standard, content: 2_000) == 840)
    // Tall keeps a few tiles from leaving a short menu: 60% of the screen, less the chrome.
    #expect(abs(cards(.tall, content: 300) - 440) < 0.001)
    #expect(cards(.tall, content: 700) == 700)
    #expect(cards(.tall, content: 2_000) == 840)
    // Fill is always the most the menu may have.
    #expect(cards(.fill, content: 300) == 840)
    #expect(cards(.fill, content: 2_000) == 840)
}
