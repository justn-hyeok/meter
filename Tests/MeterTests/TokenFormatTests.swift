import Testing
@testable import MeterCore

@Test func compactTokenCountsKeepThreeSignificantFigures() {
    #expect(TokenFormat.compact(0) == "0")
    #expect(TokenFormat.compact(999) == "999")
    #expect(TokenFormat.compact(1_000) == "1k")
    #expect(TokenFormat.compact(12_345) == "12.3k")
    #expect(TokenFormat.compact(123_456) == "123k")
    #expect(TokenFormat.compact(999_999) == "1M")
    #expect(TokenFormat.compact(4_560_000) == "4.56M")
    #expect(TokenFormat.compact(2_000_000_000) == "2B")
}

@Test func fixedWidthTokenCountsKeepTheirDecimals() {
    #expect(TokenFormat.compact(1_000, fixedWidth: true) == "1.00k")
    #expect(TokenFormat.compact(7_906_000_000, fixedWidth: true) == "7.91B")
    #expect(TokenFormat.compact(1_500) == "1.5k")
    #expect(TokenFormat.compact(1_050) == "1.05k")
}
