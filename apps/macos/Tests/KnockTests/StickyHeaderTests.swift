import Foundation
import Testing
@testable import Knock

/// WAG-324: the changes header of a stacked box stays at the top of the page while the write-up scrolls.
struct StickyHeaderTests {
    @Test func theHeaderStaysPutWhileTheBoxTopIsInView() {
        #expect(StickyHeader.offset(boxTop: 120, boxHeight: 900, headerHeight: 44) == 0)
        #expect(StickyHeader.offset(boxTop: 0, boxHeight: 900, headerHeight: 44) == 0)
    }

    @Test func theHeaderFollowsThePageOnceTheBoxTopScrollsAway() {
        #expect(StickyHeader.offset(boxTop: -300, boxHeight: 900, headerHeight: 44) == 300)
    }

    @Test func theHeaderStopsAtTheBottomOfTheBox() {
        #expect(StickyHeader.offset(boxTop: -2000, boxHeight: 900, headerHeight: 44) == 856)
        #expect(StickyHeader.offset(boxTop: -10, boxHeight: 30, headerHeight: 44) == 0)
    }
}
