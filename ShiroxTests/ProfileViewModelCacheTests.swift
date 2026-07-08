import XCTest
@testable import Shirox

@MainActor
final class ProfileViewModelCacheTests: XCTestCase {

    func testShouldRetryTrueForGenericError() {
        struct Boom: Error {}
        XCTAssertTrue(ProfileViewModel.shouldRetryFetch(Boom()))
    }

    func testShouldRetryFalseWhenOffline() {
        let offline = URLError(.notConnectedToInternet)
        XCTAssertFalse(ProfileViewModel.shouldRetryFetch(offline))
    }

    func testShouldRetryFalseWhenCancelled() {
        XCTAssertFalse(ProfileViewModel.shouldRetryFetch(CancellationError()))
    }

    func testBackoffIsExponentialAndCapped() {
        XCTAssertEqual(ProfileViewModel.retryDelay(forAttempt: 0), 2, accuracy: 0.001)
        XCTAssertEqual(ProfileViewModel.retryDelay(forAttempt: 1), 4, accuracy: 0.001)
        XCTAssertEqual(ProfileViewModel.retryDelay(forAttempt: 5), 8, accuracy: 0.001) // capped
    }
}
