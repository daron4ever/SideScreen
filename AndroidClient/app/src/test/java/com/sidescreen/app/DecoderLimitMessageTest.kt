package com.sidescreen.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderLimitMessageTest {
    @Test
    fun nativeSizeMatchesCrossPlatformWireFixture() {
        assertArrayEquals(
            byteArrayOf(0x95.toByte(), 0xF0.toByte(), 0x8D.toByte(), 0xD8.toByte()),
            encodeDecoderLimitPayload(2800, 1752),
        )
    }

    @Test
    fun payloadCannotBeMistakenForExistingMessageTypes() {
        for ((w, h) in listOf(256 to 256, 1752 to 2800, 16383 to 16383)) {
            val payload = requireNotNull(encodeDecoderLimitPayload(w, h))
            assertEquals(4, payload.size)
            assertTrue(payload.all { (it.toInt() and 0xFF) >= 128 })
        }
    }

    @Test
    fun invalidDimensionsAreOmittedAndOversizeIsBounded() {
        assertNull(encodeDecoderLimitPayload(255, 1752))
        assertNull(encodeDecoderLimitPayload(2800, -1))
        assertArrayEquals(ByteArray(4) { 0xFF.toByte() }, encodeDecoderLimitPayload(Int.MAX_VALUE, Int.MAX_VALUE))
    }

    @Test
    fun native120AdvertisementRequiresRateSupport() {
        val supported = CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 120) { w, h, fps ->
            assertEquals(120.0, fps, 0.0)
            w <= 2800 && h <= 1752
        }
        assertEquals(2800 to 1752, supported)
        val unsupported = CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 120) { _, _, _ -> false }
        assertNull(unsupported)
    }

    @Test
    fun throughputLimited120QueryRetainsSmallerSize() {
        val limit = CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 120) { w, h, fps ->
            w.toDouble() * h * fps <= 2800.0 * 1752 * 60
        }
        requireNotNull(limit)
        assertTrue(limit.first < 2800)
        assertTrue(limit.first.toDouble() * limit.second * 120 <= 2800.0 * 1752 * 60)
    }
}
