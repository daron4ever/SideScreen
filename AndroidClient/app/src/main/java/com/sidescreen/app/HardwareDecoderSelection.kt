package com.sidescreen.app

import android.media.MediaCodecInfo

/** Hardware codec capabilities and required features belonging to that exact codec. */
internal data class HardwareDecoderProfile(
    val name: String,
    val maxWidth: Int,
    val maxHeight: Int,
    val isFeatureRequired: (String) -> Boolean = { false },
    val supportsSizeAndRate: (Int, Int, Double) -> Boolean,
)

/** This stream uses an ordinary Surface, no MediaCrypto, and no tunneled playback session. */
internal fun supportsRegularPlayback(isFeatureRequired: (String) -> Boolean): Boolean =
    try {
        !isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback) &&
            !isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback)
    } catch (_: Exception) {
        // Unavailable required-feature metadata cannot establish compatibility with our setup.
        false
    }

/**
 * One selection per MIME for both advertised limits and playback. It deliberately does not
 * depend on the current display mode, negotiated resolution, or requested stream frame rate.
 */
internal class HardwareDecoderSelection(
    private val probe: (String) -> List<HardwareDecoderProfile>,
) {
    private val selections = HashMap<String, HardwareDecoderProfile?>()

    fun selectedDecoder(mime: String): HardwareDecoderProfile? =
        synchronized(selections) {
            val key = mime.lowercase()
            // Cache absent/failed probes too: a later playback attempt must not independently
            // select a different codec from the one whose limits were advertised.
            if (!selections.containsKey(key)) {
                selections[key] =
                    try {
                        probe(key)
                            .filter { supportsRegularPlayback(it.isFeatureRequired) }
                            .maxByOrNull { it.maxWidth.toLong() * it.maxHeight }
                    } catch (_: Exception) {
                        null
                    }
            }
            selections[key]
        }

    fun nominalMaxDecodeSize(mime: String): Pair<Int, Int>? =
        selectedDecoder(mime)?.let { it.maxWidth to it.maxHeight }

    fun maxStreamSize(
        mime: String,
        panelWidth: Int,
        panelHeight: Int,
        fps: Int,
    ): Pair<Int, Int>? {
        if (panelWidth <= 0 || panelHeight <= 0) return null
        val selected = selectedDecoder(mime) ?: return null
        return CodecCapabilities.selectStreamSize(
            panelWidth,
            panelHeight,
            selected.maxWidth,
            selected.maxHeight,
            fps,
            selected.supportsSizeAndRate,
        )
    }

    /**
     * The legacy resolution/rate search is available only without a shared hardware selection.
     * Creation failure propagates; trying another identity would invalidate advertised limits.
     * Factory arguments keep this decision testable without invoking native MediaCodec APIs.
     */
    fun <T> createDecoder(
        mime: String,
        findLegacyDecoder: () -> String?,
        createByName: (String) -> T,
        createByType: (String) -> T,
    ): T {
        val name = selectedDecoder(mime)?.name ?: findLegacyDecoder()
        return if (name != null) createByName(name) else createByType(mime)
    }
}
