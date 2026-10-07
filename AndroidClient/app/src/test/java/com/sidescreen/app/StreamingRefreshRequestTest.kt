package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test

class StreamingRefreshRequestTest {
    private val request = StreamingRefreshRequest()
    private val rates = listOf(30f, 60f, 120.00001f)

    private fun selected(
        resumed: Boolean = true,
        surface: Boolean = true,
    ) = request.preferredRate(resumed, surface, rates)

    private fun connect(): Long = request.beginConnection().also { request.updateConnection(it, true) }

    @Test
    fun onlyConnectedForegroundSurfaceRequestsRefresh() {
        assertEquals(0f, selected(), 0f)
        val attempt = request.beginConnection()
        assertEquals(0f, selected(), 0f)
        request.updateConnection(attempt, true)
        assertEquals(120.00001f, selected(), 0f)
        assertEquals(0f, selected(resumed = false), 0f)
        assertEquals(0f, selected(surface = false), 0f)
        assertEquals(120.00001f, selected(), 0f)
    }

    @Test
    fun explicitDisconnectRejectsLateConnectionSuccess() {
        val attempt = connect()
        request.endConnection()
        request.updateConnection(attempt, true)
        assertEquals(0f, selected(), 0f)
    }

    @Test
    fun oldDisconnectCannotClearNewConnection() {
        val old = connect()
        connect()
        request.updateConnection(old, false)
        assertEquals(120.00001f, selected(), 0f)
    }

    @Test
    fun oldSuccessCannotEnablePendingReconnect() {
        val old = connect()
        request.beginConnection()
        request.updateConnection(old, true)
        assertEquals(0f, selected(), 0f)
    }

    @Test
    fun remoteDisconnectRemainsReleasedOnResume() {
        val attempt = connect()
        request.updateConnection(attempt, false)
        request.updateConnection(attempt, false)
        assertEquals(0f, selected(resumed = false), 0f)
        assertEquals(0f, selected(), 0f)
    }

    @Test
    fun supportsSlowerPanelsAndCapsFasterPanels() {
        connect()
        assertEquals(60f, request.preferredRate(true, true, listOf(30f, 60f)), 0f)
        assertEquals(90f, request.preferredRate(true, true, listOf(60f, 90f, 144f)), 0f)
        assertEquals(120f, request.preferredRate(true, true, listOf(60f, 120f, 144f)), 0f)
    }

    @Test
    fun invalidOrUnavailableModesReleasePreference() {
        connect()
        assertEquals(0f, request.preferredRate(true, true, emptyList()), 0f)
        val invalid = listOf(Float.NaN, Float.POSITIVE_INFINITY, 0f, -1f, 144f)
        assertEquals(0f, request.preferredRate(true, true, invalid), 0f)
    }
}
