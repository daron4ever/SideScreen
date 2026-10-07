package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostPingTrackerTest {
    private val tracker = HostPingTracker()

    @Test
    fun onlyThisClientsRecentEchoCanRefreshHostLiveness() {
        tracker.sent(123L, 1_000)
        assertFalse(tracker.receive(456L, 1_001))
        assertTrue(tracker.receive(123L, 1_001))
        assertFalse(tracker.receive(123L, 1_002)) // Duplicate echoes cannot renew freshness.
    }

    @Test
    fun bufferedPreSleepPongExpiresUsingElapsedTime() {
        tracker.sent(123L, 1_000)
        assertFalse(tracker.receive(123L, 11_000))
        tracker.sent(456L, 12_000)
        assertTrue(tracker.receive(456L, 12_001))
    }

    @Test
    fun unansweredPingsArePrunedWhileNewProbesContinue() {
        tracker.sent(123L, 1_000)
        tracker.sent(456L, 11_000)
        assertFalse(tracker.receive(123L, 11_001))
        assertTrue(tracker.receive(456L, 11_001))
    }

    @Test
    fun queuedWriteBurstRetainsOnlyTenRecentProbes() {
        for (timestamp in 1L..11L) tracker.sent(timestamp, 1_000)
        assertFalse(tracker.receive(1L, 1_001))
        assertTrue(tracker.receive(2L, 1_001))
        assertTrue(tracker.receive(11L, 1_001))
    }

    @Test
    fun failedWritesAndDisconnectCannotLeaveFreshReplies() {
        tracker.sent(123L, 1_000)
        tracker.discard(123L)
        assertFalse(tracker.receive(123L, 1_001))
        tracker.sent(456L, 2_000)
        tracker.clear()
        assertFalse(tracker.receive(456L, 2_001))
    }

    @Test
    fun oldClientsAsynchronousCleanupDoesNotClearNewClientsPings() {
        val nextClientTracker = HostPingTracker()
        tracker.sent(123L, 1_000)
        nextClientTracker.sent(456L, 1_001)
        tracker.clear()
        assertTrue(nextClientTracker.receive(456L, 1_002))
        assertFalse(nextClientTracker.receive(123L, 1_002))
    }

    @Test
    fun invalidNegativeProbeAgeIsRejected() {
        tracker.sent(123L, 2_000)
        assertFalse(tracker.receive(123L, 1_000))
    }
}
