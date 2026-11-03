import Foundation
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct StatusItemClickRouterTests {
  private final class Calls {
    var windows = 0
    var menus = 0
  }

  private func makeRouter(_ calls: Calls) -> StatusItemClickRouter {
    StatusItemClickRouter(
      doubleClickInterval: 0.05,
      showWindow: { calls.windows += 1 },
      showMenu: { calls.menus += 1 })
  }

  @Test
  func aDoubleClickShowsTheWindowAndNoMenu() async throws {
    let calls = Calls()
    let router = makeRouter(calls)

    router.click(count: 1, opensMenuAtOnce: false)
    router.click(count: 2, opensMenuAtOnce: false)
    try await Task.sleep(for: .milliseconds(200))

    #expect(calls.windows == 1)
    #expect(calls.menus == 0)
  }

  @Test
  func aSingleClickShowsTheMenuAfterTheDoubleClickInterval() async throws {
    let calls = Calls()
    let router = makeRouter(calls)

    router.click(count: 1, opensMenuAtOnce: false)
    #expect(calls.menus == 0)
    // Other suites keep the main actor busy, so wait for the menu, not a time.
    let deadline = ContinuousClock.now + .seconds(60)
    while calls.menus == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    #expect(calls.menus == 1)
    #expect(calls.windows == 0)
  }

  @Test
  func aRightClickShowsTheMenuAtOnce() {
    let calls = Calls()
    let router = makeRouter(calls)

    router.click(count: 1, opensMenuAtOnce: true)

    #expect(calls.menus == 1)
    #expect(calls.windows == 0)
  }

  @Test
  func cancellingDropsAWaitingSingleClick() async throws {
    let calls = Calls()
    let router = makeRouter(calls)

    router.click(count: 1, opensMenuAtOnce: false)
    router.cancel()
    try await Task.sleep(for: .milliseconds(200))

    #expect(calls.menus == 0)
    #expect(calls.windows == 0)
  }
}
