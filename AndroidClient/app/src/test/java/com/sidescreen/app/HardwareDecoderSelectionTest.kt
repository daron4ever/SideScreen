package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HardwareDecoderSelectionTest {
    private val hevc = "video/hevc"
    private val avc = "video/avc"
    private val panel = 2800 to 1752

    @Test
    fun advertisedLimitsAndPlaybackUseTheLargerDecoderInsteadOfTheFirst60HzDecoder() {
        val queries = mutableListOf<String>()
        val first = profile("first-native60", 4096, 2160, 60, queries)
        val larger = profile("larger-native120", 8192, 4352, 120, queries)
        val selection = HardwareDecoderSelection { listOf(first, larger) }

        assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 60))
        assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 120))
        assertEquals(8192 to 4352, selection.nominalMaxDecodeSize(hevc))
        assertEquals("larger-native120", createNamedDecoder(selection, hevc))
        assertTrue(queries.isNotEmpty())
        assertTrue(queries.all { it == "larger-native120" })
    }

    @Test
    fun playbackBeforeRefreshModeChangePinsTheSameDecoderForLater120HzAdvertisement() {
        var displayRefreshHz = 60
        var legacySearches = 0
        val selection = HardwareDecoderSelection {
            listOf(
                profile("first-native60", 4096, 2160, 60),
                profile("larger-native120", 8192, 4352, 120),
            )
        }
        fun createForCurrentDisplay(): String =
            selection.createDecoder(
                hevc,
                {
                    legacySearches++
                    if (displayRefreshHz == 60) "first-native60" else "larger-native120"
                },
                { it },
                { error("Selected hardware must be created by name") },
            )

        assertEquals("larger-native120", createForCurrentDisplay())
        assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 120))
        displayRefreshHz = 120
        assertEquals("larger-native120", createForCurrentDisplay())
        assertEquals(0, legacySearches)
    }

    @Test
    fun throughputLimitAt120HzDoesNotSwitchToAnotherDecoder() {
        val selection = HardwareDecoderSelection {
            listOf(
                profile("smaller-native120", 4096, 2160, 120),
                profile("larger-native60", 8192, 4352, 60),
            )
        }

        assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 60))
        val reduced = requireNotNull(selection.maxStreamSize(hevc, panel.first, panel.second, 120))
        assertTrue(reduced.first < panel.first)
        assertTrue(reduced.first.toDouble() * reduced.second * 120 <= panel.first.toDouble() * panel.second * 60)
        assertEquals("larger-native60", createNamedDecoder(selection, hevc))
    }

    @Test
    fun equalNominalAreasRetainTheFirstDecoder() {
        val first = profile("first", 4096, 2160, 60)
        val second = profile("second", 4096, 2160, 120)
        val selection = HardwareDecoderSelection { listOf(first, second) }

        assertSame(first, selection.selectedDecoder(hevc))
        assertEquals("first", createNamedDecoder(selection, hevc))
    }

    @Test
    fun largerSecureOrTunneledOnlyDecoderCannotOwnAdvertisedLimitsOrPlayback() {
        for (requiredFeature in listOf("secure-playback", "tunneled-playback")) {
            val queries = mutableListOf<String>()
            val ordinary = profile("ordinary", 4096, 2160, 60, queries)
            val specialized =
                profile("specialized", 8192, 4352, 120, queries).copy(
                    isFeatureRequired = { it == requiredFeature },
                )
            val selection = HardwareDecoderSelection { listOf(ordinary, specialized) }

            assertEquals(4096 to 2160, selection.nominalMaxDecodeSize(hevc))
            assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 60))
            val reduced = requireNotNull(selection.maxStreamSize(hevc, panel.first, panel.second, 120))
            assertTrue(reduced.first < panel.first)
            assertEquals("ordinary", createNamedDecoder(selection, hevc))
            assertTrue(queries.isNotEmpty())
            assertTrue(queries.all { it == "ordinary" })
        }
    }

    @Test
    fun specializedOnlyCandidatesAdvertiseNoLimitsAndLeaveLegacyFallbackAvailable() {
        val candidates =
            listOf("secure-playback", "tunneled-playback").map { feature ->
                profile("requires-$feature", 8192, 4352, 120).copy(
                    isFeatureRequired = { it == feature },
                )
            }
        val selection = HardwareDecoderSelection { candidates }

        assertNull(selection.nominalMaxDecodeSize(hevc))
        assertNull(selection.maxStreamSize(hevc, panel.first, panel.second, 60))
        assertNull(selection.maxStreamSize(hevc, panel.first, panel.second, 120))
        assertEquals(
            "regular-legacy-software",
            selection.createDecoder(
                hevc,
                { "regular-legacy-software" },
                { it },
                { error("Legacy decoder name is available") },
            ),
        )
    }

    @Test
    fun optionalSecureAndTunneledFeaturesDoNotExcludeRegularPlayback() {
        val queriedFeatures = mutableListOf<String>()
        // Both features may be supported, but neither is required for this ordinary setup.
        val optional =
            profile("optional-features", 8192, 4352, 120).copy(
                isFeatureRequired = {
                    queriedFeatures.add(it)
                    false
                },
            )
        val selection = HardwareDecoderSelection {
            listOf(profile("ordinary", 4096, 2160, 60), optional)
        }

        assertEquals(8192 to 4352, selection.nominalMaxDecodeSize(hevc))
        assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 120))
        assertEquals("optional-features", createNamedDecoder(selection, hevc))
        assertEquals(listOf("secure-playback", "tunneled-playback"), queriedFeatures)
    }

    @Test
    fun candidateFeatureQueryFailureDoesNotDiscardOtherOrdinaryDecoders() {
        for (failedFeature in listOf("secure-playback", "tunneled-playback")) {
            val failed =
                profile("metadata-unavailable", 8192, 4352, 120).copy(
                    isFeatureRequired = {
                        if (it == failedFeature) error("Feature metadata unavailable")
                        false
                    },
                )
            val selection = HardwareDecoderSelection {
                listOf(profile("ordinary", 4096, 2160, 60), failed)
            }

            assertEquals(4096 to 2160, selection.nominalMaxDecodeSize(hevc))
            assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 60))
            assertEquals("ordinary", createNamedDecoder(selection, hevc))
        }
    }

    @Test
    fun onlyFailedFeatureQueriesAreCachedAsAbsentAndPreserveDefaultCreationFallback() {
        var probes = 0
        val selection = HardwareDecoderSelection {
            probes++
            listOf(
                profile("metadata-unavailable", 8192, 4352, 120).copy(
                    isFeatureRequired = { error("Feature metadata unavailable") },
                ),
            )
        }

        assertNull(selection.nominalMaxDecodeSize(hevc))
        assertNull(selection.maxStreamSize("VIDEO/HEVC", panel.first, panel.second, 120))
        assertEquals(
            "default-$hevc",
            selection.createDecoder(hevc, { null }, { error("No legacy name") }, { "default-$it" }),
        )
        assertEquals(1, probes)
    }

    @Test
    fun selectionIsCachedPerMimeAcrossCasePanelChangesAndPlaybackRecreation() {
        val probes = mutableListOf<String>()
        val selection = HardwareDecoderSelection { mime ->
            probes.add(mime)
            listOf(profile("codec-$mime", 8192, 4352, 120))
        }

        assertEquals(panel, selection.maxStreamSize("VIDEO/HEVC", panel.first, panel.second, 60))
        assertEquals("codec-$hevc", createNamedDecoder(selection, hevc))
        assertEquals(1920 to 1200, selection.maxStreamSize(hevc, 1920, 1200, 120))
        assertEquals("codec-$hevc", createNamedDecoder(selection, "Video/Hevc"))
        assertEquals("codec-$avc", createNamedDecoder(selection, avc))
        assertEquals(8192 to 4352, selection.nominalMaxDecodeSize("VIDEO/AVC"))
        assertEquals(listOf(hevc, avc), probes)
    }

    @Test
    fun absentSelectionIsCachedIncludingMimeCaseAndAllowsLegacyNamedPlayback() {
        var probes = 0
        val selection = HardwareDecoderSelection {
            probes++
            emptyList()
        }

        assertNull(selection.nominalMaxDecodeSize(hevc))
        assertNull(selection.maxStreamSize("VIDEO/HEVC", panel.first, panel.second, 120))
        val created =
            selection.createDecoder(
                hevc,
                { "legacy-software" },
                { it },
                { error("Legacy name exists") },
            )
        assertEquals("legacy-software", created)
        assertEquals(1, probes)
    }

    @Test
    fun probeFailureIsCachedAndDoesNotDisableOtherMimesOrLegacyFallback() {
        val probes = mutableListOf<String>()
        val selection = HardwareDecoderSelection { mime ->
            probes.add(mime)
            if (mime == hevc) error("Capability enumeration unavailable")
            listOf(profile("avc-hardware", 4096, 2160, 60))
        }

        assertNull(selection.nominalMaxDecodeSize(hevc))
        assertNull(selection.maxStreamSize("VIDEO/HEVC", panel.first, panel.second, 60))
        assertEquals(
            "default-$hevc",
            selection.createDecoder(hevc, { null }, { error("No legacy name") }, { "default-$it" }),
        )
        assertEquals("avc-hardware", createNamedDecoder(selection, avc))
        assertEquals(listOf(hevc, avc), probes)
    }

    @Test
    fun selectedCapabilityQueryFailureDoesNotChangePlaybackIdentity() {
        val selected =
            HardwareDecoderProfile("selected", 8192, 4352) { _, _, _ ->
                error("Rate query unavailable")
            }
        val selection = HardwareDecoderSelection {
            listOf(profile("other", 4096, 2160, 120), selected)
        }

        assertNull(selection.maxStreamSize(hevc, panel.first, panel.second, 120))
        assertEquals(8192 to 4352, selection.nominalMaxDecodeSize(hevc))
        assertEquals("selected", createNamedDecoder(selection, hevc))
        assertSame(selected, selection.selectedDecoder(hevc))
    }

    @Test
    fun selectedCreationFailurePropagatesWithoutLegacySearchOrDefaultCreation() {
        val selection = HardwareDecoderSelection { listOf(profile("selected", 8192, 4352, 120)) }
        val failure = IllegalStateException("Selected codec unavailable")
        val creations = mutableListOf<String>()
        var legacySearches = 0
        var defaultCreations = 0

        assertEquals(panel, selection.maxStreamSize(hevc, panel.first, panel.second, 120))
        try {
            selection.createDecoder(
                hevc,
                {
                    legacySearches++
                    "different-hardware"
                },
                {
                    creations.add(it)
                    throw failure
                },
                {
                    defaultCreations++
                    "default-$it"
                },
            )
            fail("Selected codec creation must propagate the failure")
        } catch (caught: IllegalStateException) {
            assertSame(failure, caught)
        }
        assertEquals(listOf("selected"), creations)
        assertEquals(0, legacySearches)
        assertEquals(0, defaultCreations)
        assertEquals("selected", createNamedDecoder(selection, hevc))
    }

    @Test
    fun invalidPanelDoesNotProbeHardware() {
        val selection = HardwareDecoderSelection { error("Invalid panel must not probe") }

        assertNull(selection.maxStreamSize(hevc, 0, panel.second, 120))
    }

    @Test
    fun brokenHevcExclusionIsCaseInsensitiveAndDoesNotExcludeAvc() {
        for (name in listOf("OMX.sprd.hevc", "c2.sprd.hevc", "C2.SPRD.HEVC")) {
            assertTrue(CodecCapabilities.isBrokenHevcDecoder(name, "VIDEO/HEVC"))
            assertFalse(CodecCapabilities.isBrokenHevcDecoder(name, avc))
        }
        assertFalse(CodecCapabilities.isBrokenHevcDecoder("c2.vendor.hevc", hevc))
    }

    @Test
    fun softwareClassificationIsSharedAndCaseInsensitive() {
        assertTrue(CodecCapabilities.isSoftwareDecoder("c2.android.hevc.decoder"))
        assertTrue(CodecCapabilities.isSoftwareDecoder("OMX.google.h264.decoder"))
        assertTrue(CodecCapabilities.isSoftwareDecoder("C2.ANDROID.AVC"))
        assertFalse(CodecCapabilities.isSoftwareDecoder("c2.vendor.hevc"))
    }

    private fun profile(
        name: String,
        maxWidth: Int,
        maxHeight: Int,
        nativeFps: Int,
        queries: MutableList<String>? = null,
    ): HardwareDecoderProfile =
        HardwareDecoderProfile(name, maxWidth, maxHeight) { width, height, fps ->
            queries?.add(name)
            width <= maxWidth && height <= maxHeight &&
                width.toDouble() * height * fps <= panel.first.toDouble() * panel.second * nativeFps
        }

    private fun createNamedDecoder(selection: HardwareDecoderSelection, mime: String): String =
        selection.createDecoder(
            mime,
            { error("Shared hardware selection must bypass the legacy search") },
            { it },
            { error("Shared hardware selection must bypass creation by MIME") },
        )
}
