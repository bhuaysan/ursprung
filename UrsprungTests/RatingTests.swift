// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import Ursprung

@Suite("Inspector rating")
struct RatingTests {
    @Test(arguments: [
        (0.0, 0),
        (0.09, 0),
        (0.1, 1), // half a star rounds up
        (0.5, 3),
        (0.8, 4),
        (0.95, 5),
        (1.0, 5),
        (1.4, 5), // out of range values stay within five stars
        (-0.2, 0),
    ])
    func ratingsRoundToWholeStars(value: Double, expected: Int) {
        #expect(RatingView.stars(for: value) == expected)
    }
}
