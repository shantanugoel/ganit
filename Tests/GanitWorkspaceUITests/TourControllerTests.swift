import AppKit
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct TourControllerTests {
  @Test
  func skipFinishesWithoutWalkingEveryStep() {
    var finished = 0
    let tour = TourController { finished += 1 }
    tour.loadView()
    #expect(tour.index == 0)
    tour.skip(nil)
    #expect(finished == 1)
  }

  @Test
  func nextReachesDoneThenFinishes() {
    var finished = 0
    let tour = TourController { finished += 1 }
    tour.loadView()
    for _ in 0..<(TourController.steps.count - 1) {
      tour.advance(nil)
    }
    #expect(tour.index == TourController.steps.count - 1)
    #expect(finished == 0)
    tour.advance(nil)
    #expect(finished == 1)
  }
}
