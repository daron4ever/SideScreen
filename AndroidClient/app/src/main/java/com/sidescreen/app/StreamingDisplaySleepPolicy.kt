package com.sidescreen.app

import java.io.DataInputStream
import java.io.IOException

internal const val HOST_REPLY_FRESHNESS_MS = 10_000L

/** Main-thread ownership of the current connection's screen-on request. */
internal class StreamingDisplaySleepPolicy {
    private var attempt: Long? = null
    private var connected = false
    private var hostAwake = true // Hosts predating display-state messages retain the active-use policy.
    private var lastReplyMs: Long? = null

    fun beginConnection(sourceAttempt: Long) {
        attempt = sourceAttempt
        connected = false
        hostAwake = true
        lastReplyMs = null
    }

    fun isCurrentAttempt(sourceAttempt: Long): Boolean = attempt == sourceAttempt

    fun endConnection() {
        attempt = null
        connected = false
        hostAwake = true
        lastReplyMs = null
    }

    fun updateConnection(
        sourceAttempt: Long,
        isConnected: Boolean,
    ) {
        if (!isCurrentAttempt(sourceAttempt)) return
        if (isConnected) {
            connected = true
        } else {
            endConnection()
        }
    }

    fun receiveHostDisplayState(
        sourceAttempt: Long,
        awake: Boolean,
        receivedAtMs: Long,
    ) {
        if (!isCurrentAttempt(sourceAttempt) || !connected) return
        hostAwake = awake
        lastReplyMs = receivedAtMs
    }

    fun receiveHostReply(
        sourceAttempt: Long,
        receivedAtMs: Long,
    ) {
        if (!isCurrentAttempt(sourceAttempt) || !connected) return
        lastReplyMs = receivedAtMs
    }

    fun shouldKeepScreenOn(
        resumed: Boolean,
        nowMs: Long,
    ): Boolean {
        val receivedAtMs = lastReplyMs ?: return false
        val ageMs = nowMs - receivedAtMs
        return connected && resumed && hostAwake && ageMs >= 0L && ageMs < HOST_REPLY_FRESHNESS_MS
    }
}

/** Fixed-width messages: invalid state closes the stream after consuming exactly one byte. */
internal object HostDisplayStateMessage {
    const val CLIENT_SUPPORTS_HOST_DISPLAY_STATE = 15
    const val SERVER_HOST_DISPLAY_STATE = 16

    fun readAwake(input: DataInputStream): Boolean =
        when (val state = input.readUnsignedByte()) {
            0 -> false
            1 -> true
            else -> throw IOException("Invalid host display state: $state")
        }
}

/** Matches pong echoes to this client's recent probes, including time spent in device sleep. */
internal class HostPingTracker {
    private val sentAtMsByTimestamp = mutableMapOf<Long, Long>()

    @Synchronized
    fun sent(
        timestamp: Long,
        nowMs: Long,
    ) {
        sentAtMsByTimestamp.entries.removeAll { nowMs - it.value >= HOST_REPLY_FRESHNESS_MS }
        // One probe per second normally retains fewer than ten. Bound queued-write bursts too.
        if (sentAtMsByTimestamp.size >= 10) {
            sentAtMsByTimestamp.remove(sentAtMsByTimestamp.keys.first())
        }
        sentAtMsByTimestamp[timestamp] = nowMs
    }

    @Synchronized
    fun receive(
        timestamp: Long,
        nowMs: Long,
    ): Boolean {
        val sentAtMs = sentAtMsByTimestamp.remove(timestamp) ?: return false
        val ageMs = nowMs - sentAtMs
        return ageMs >= 0L && ageMs < HOST_REPLY_FRESHNESS_MS
    }

    @Synchronized
    fun discard(timestamp: Long) {
        sentAtMsByTimestamp.remove(timestamp)
    }

    @Synchronized
    fun clear() {
        sentAtMsByTimestamp.clear()
    }
}
