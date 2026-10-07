package com.sidescreen.app

/** Main-thread state for the window preference; never changes system settings. */
internal class StreamingRefreshRequest {
    private var attempt = 0L
    private var connected = false

    fun beginConnection(): Long {
        attempt++
        connected = false
        return attempt
    }

    fun endConnection() {
        attempt++
        connected = false
    }

    fun updateConnection(
        sourceAttempt: Long,
        isConnected: Boolean,
    ) {
        if (sourceAttempt == attempt) connected = isConnected
    }

    fun preferredRate(
        resumed: Boolean,
        hasSurface: Boolean,
        supportedRates: List<Float>,
    ): Float {
        if (!connected || !resumed || !hasSurface) return 0f
        // Nominal 120 Hz modes can be reported slightly above 120 (e.g. 120.00001).
        return supportedRates.filter { it.isFinite() && it > 0f && it <= 120.5f }.maxOrNull() ?: 0f
    }
}
