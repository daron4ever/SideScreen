package com.sidescreen.app

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamingDisplaySleepPolicyTest {
    private val policy = StreamingDisplaySleepPolicy()
    private val attempt = 1L

    private fun connect(sourceAttempt: Long = attempt) {
        policy.beginConnection(sourceAttempt)
        policy.updateConnection(sourceAttempt, true)
    }

    private fun keepOn(
        nowMs: Long,
        resumed: Boolean = true,
    ) = policy.shouldKeepScreenOn(resumed, nowMs)

    @Test
    fun connectedHostAwakeSleepAndWakeFollowExplicitState() {
        connect()
        policy.receiveHostDisplayState(attempt, true, 1_000)
        assertTrue(keepOn(1_000))
        policy.receiveHostDisplayState(attempt, false, 2_000)
        assertFalse(keepOn(2_000))
        policy.receiveHostReply(attempt, 3_000)
        assertFalse(keepOn(3_000)) // Pong while only the host displays sleep cannot override asleep.
        policy.receiveHostDisplayState(attempt, true, 4_000)
        assertTrue(keepOn(4_000))
    }

    @Test
    fun silentHostReleasesAtTenSecondsWithoutUsingFrameActivity() {
        connect()
        policy.receiveHostDisplayState(attempt, true, 1_000)
        assertTrue(keepOn(10_999))
        assertFalse(keepOn(11_000))
        policy.receiveHostReply(attempt, 12_000)
        assertTrue(keepOn(12_000))
    }

    @Test
    fun legacyHostNeedsFreshPongBeforeKeepingScreenOn() {
        connect()
        assertFalse(keepOn(1_000))
        policy.receiveHostReply(attempt, 1_000)
        assertTrue(keepOn(1_000))
        assertFalse(keepOn(11_000))
    }

    @Test
    fun foregroundAndResumeUseReceiveTimeRatherThanCallbackDispatchTime() {
        connect()
        policy.receiveHostReply(attempt, 1_000)
        assertFalse(keepOn(1_001, resumed = false))
        policy.receiveHostDisplayState(attempt, true, 2_000)
        assertFalse(keepOn(2_000, resumed = false))
        assertTrue(keepOn(2_001))
        assertFalse(keepOn(12_000)) // Resume or a delayed UI callback cannot renew this reply.
    }

    @Test
    fun repliesBeforeConnectionSuccessCannotEnablePendingConnection() {
        policy.beginConnection(attempt)
        policy.receiveHostDisplayState(attempt, true, 1_000)
        policy.receiveHostReply(attempt, 1_000)
        policy.updateConnection(attempt, true)
        assertFalse(keepOn(1_000))
    }

    @Test
    fun explicitStopRejectsAllLateCallbacks() {
        connect()
        policy.receiveHostDisplayState(attempt, true, 1_000)
        policy.endConnection()
        policy.updateConnection(attempt, true)
        policy.receiveHostDisplayState(attempt, true, 2_000)
        policy.receiveHostReply(attempt, 2_000)
        assertFalse(keepOn(2_000))
    }

    @Test
    fun remoteDisconnectRejectsLateSuccessAndRepliesOnSameClient() {
        connect()
        policy.receiveHostReply(attempt, 1_000)
        policy.updateConnection(attempt, false)
        policy.updateConnection(attempt, true)
        policy.receiveHostDisplayState(attempt, true, 2_000)
        policy.receiveHostReply(attempt, 2_000)
        assertFalse(keepOn(2_000))
    }

    @Test
    fun newAttemptResetsStateAndRejectsOldStateSuccessAndPong() {
        connect()
        policy.receiveHostDisplayState(attempt, false, 1_000)
        policy.beginConnection(2L)
        policy.updateConnection(attempt, true)
        policy.receiveHostDisplayState(attempt, true, 2_000)
        policy.receiveHostReply(attempt, 2_000)
        assertFalse(keepOn(2_000))
        policy.updateConnection(2L, true)
        assertFalse(keepOn(2_000))
        policy.receiveHostReply(2L, 3_000)
        assertTrue(keepOn(3_000)) // The new legacy host does not inherit the old host's asleep state.
        policy.receiveHostDisplayState(attempt, false, 3_001)
        policy.updateConnection(attempt, false)
        assertTrue(keepOn(3_001))
    }

    @Test
    fun futureTimestampCannotKeepScreenOn() {
        connect()
        policy.receiveHostReply(attempt, 2_000)
        assertFalse(keepOn(1_000))
    }
}
