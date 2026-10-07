package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamSizeSelectionTest {
    @Test
    fun preservesNativeLandscapeSizeWhenDecoderSupportsIt() {
        val size = CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 60) { w, h, fps ->
            assertEquals(60.0, fps, 0.0)
            w == 2800 && h == 1752
        }
        assertEquals(2800 to 1752, size)
    }

    @Test
    fun preservesNativePortraitSizeWhenDecoderSupportsIt() {
        val size = CodecCapabilities.selectStreamSize(1752, 2800, 8192, 4352, 60) { w, h, _ ->
            w == 1752 && h == 2800
        }
        assertEquals(1752 to 2800, size)
    }

    @Test
    fun retainsAlignedFallbackForDecoderRequiringMultiplesOf16() {
        val size = CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 60) { w, h, _ ->
            w % 16 == 0 && h % 16 == 0
        }
        assertEquals(2800 to 1744, size)
    }

    @Test
    fun shrinksUntilTheFrameRateBudgetIsSupported() {
        val checked = mutableListOf<Pair<Int, Int>>()
        val size = CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 60) { w, h, fps ->
            checked.add(w to h)
            w.toLong() * h * fps <= 1920L * 1200 * 60
        }
        requireNotNull(size)
        assertTrue(checked.size > 2)
        assertTrue(size.first.toLong() * size.second <= 1920L * 1200)
        assertEquals(0, size.first % 16)
        assertEquals(0, size.second % 16)
        assertEquals(size, checked.last())
    }

    @Test
    fun respectsMaximumDimensionsBeforeProbing() {
        val size = CodecCapabilities.selectStreamSize(2800, 1752, 1920, 1088, 60) { w, h, _ ->
            assertTrue(w <= 1920 && h <= 1088)
            true
        }
        assertEquals(1920 to 1088, size)
    }

    @Test
    fun unsupportedSizeExceptionUsesExistingFallback() {
        val size = CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 60) { _, h, _ ->
            if (h == 1752) throw IllegalArgumentException("Unsupported size")
            true
        }
        assertEquals(2800 to 1744, size)
    }

    @Test
    fun capabilityFailureReturnsNoAdvertisedLimit() {
        assertNull(CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 60) { _, _, _ ->
            throw IllegalStateException("Capability unavailable")
        })
    }

    @Test
    fun invalidPanelDoesNotQueryDecoder() {
        assertNull(CodecCapabilities.selectStreamSize(0, 1752, 8192, 4352, 60) { _, _, _ ->
            error("Invalid panel must not be queried")
        })
    }

    @Test
    fun oddNativeDimensionsRetainEvenAlignedFallback() {
        val size = CodecCapabilities.selectStreamSize(2801, 1753, 8192, 4352, 60) { w, h, _ ->
            assertEquals(0, w % 2)
            assertEquals(0, h % 2)
            true
        }
        assertEquals(2800 to 1744, size)
    }

    @Test
    fun noSupportedSizeReturnsNoAdvertisedLimit() {
        assertNull(CodecCapabilities.selectStreamSize(2800, 1752, 8192, 4352, 60) { _, _, _ -> false })
    }
}
