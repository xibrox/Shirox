import XCTest
@testable import Shirox
#if os(iOS)
import UIKit

final class QuickActionTests: XCTestCase {

    func testShortcutItemTypesAreStableAndDistinct() {
        XCTAssertEqual(QuickAction.search.shortcutItemType, "com.shirox.quickaction.search")
        XCTAssertEqual(QuickAction.downloads.shortcutItemType, "com.shirox.quickaction.downloads")
        XCTAssertEqual(QuickAction.library.shortcutItemType, "com.shirox.quickaction.library")
    }

    func testInitFromShortcutItemRoundTripsEachCase() {
        for action in QuickAction.allCases {
            let item = UIApplicationShortcutItem(type: action.shortcutItemType,
                                                 localizedTitle: action.title)
            XCTAssertEqual(QuickAction(item), action)
        }
    }

    func testInitFromUnknownShortcutItemReturnsNil() {
        let item = UIApplicationShortcutItem(type: "com.shirox.quickaction.bogus",
                                             localizedTitle: "Bogus")
        XCTAssertNil(QuickAction(item))
    }

    func testRegisteredItemsMatchAllCasesInOrder() {
        let items = QuickAction.registeredItems
        XCTAssertEqual(items.map { $0.type }, [
            "com.shirox.quickaction.search",
            "com.shirox.quickaction.downloads",
            "com.shirox.quickaction.library"
        ])
        XCTAssertEqual(items.map { $0.localizedTitle }, ["Search", "Downloads", "Library"])
        XCTAssertTrue(items.allSatisfy { $0.icon != nil })
    }
}
#endif
