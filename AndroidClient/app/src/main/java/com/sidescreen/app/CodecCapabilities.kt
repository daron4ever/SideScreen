package com.sidescreen.app

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat

/**
 * One-shot decoder capability probe. AVC-only devices drive the H.264
 * wire-protocol negotiation (the Mac encodes H.264 instead of HEVC).
 *
 * "Has HEVC" means the device has a *usable hardware* HEVC decoder — not merely
 * any decoder that advertises the type. The decoder must work with an ordinary
 * Surface without secure or tunneled playback. Two other classes of device are
 * deliberately routed to H.264 instead:
 *
 *  - **Software-only HEVC** (e.g. Onyx Boox Nova Air C, whose vendor
 *    media_codecs.xml disables HW HEVC): the Google software decoder
 *    (c2.android.hevc / OMX.google.hevc) is far too slow for real-time mirroring.
 *
 *  - **Broken vendor HW HEVC**: Spreadtrum/Unisoc (OMX.sprd.hevc, c2.sprd.*)
 *    advertise a HW HEVC decoder that configures and starts successfully but
 *    never renders decoded frames to the output Surface — the SurfaceView stays
 *    empty and the user sees a black screen (e.g. Yuho Tab 10, SC9863A + PowerVR).
 *
 * Both classes have a working hardware H.264 decoder, so H.264 is the reliable
 * path for them.
 */
object CodecCapabilities {
    /** Decoder-name prefixes whose HEVC implementation is unusable for surface output. */
    private val BROKEN_HEVC_HW_PREFIXES = listOf("omx.sprd.", "c2.sprd.")

    /**
     * Usable *hardware* decoder for [mime]: not an encoder, not the (too slow
     * for real-time mirroring) Google software implementation, and for HEVC
     * not one of the vendor implementations that never render to a Surface.
     * Shared by [hasHevcDecoder] and the hardware selection used for advertised
     * limits and playback so their classification cannot drift.
     */
    private fun isUsableHardwareDecoder(
        info: MediaCodecInfo,
        mime: String,
    ): Boolean {
        if (info.isEncoder) return false
        if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) return false
        return !isSoftwareDecoder(info.name) && !isBrokenHevcDecoder(info.name, mime)
    }

    internal fun isSoftwareDecoder(name: String): Boolean {
        val lowerName = name.lowercase()
        return lowerName.startsWith("c2.android.") || lowerName.startsWith("omx.google.")
    }

    internal fun isBrokenHevcDecoder(name: String, mime: String): Boolean =
        mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
            BROKEN_HEVC_HW_PREFIXES.any { name.lowercase().startsWith(it) }

    val hasHevcDecoder: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
                isUsableHardwareDecoder(info, MediaFormat.MIMETYPE_VIDEO_HEVC) &&
                    try {
                        val caps = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC)
                        supportsRegularPlayback(caps::isFeatureRequired)
                    } catch (_: Exception) {
                        false
                    }
            }
        } catch (_: Exception) {
            true // fail open: assume HEVC, preserving legacy behavior
        }
    }

    /** Mime the client will ask the Mac to stream: HEVC when usable, else AVC. */
    val streamMime: String
        get() = if (hasHevcDecoder) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private val hardwareSelection = HardwareDecoderSelection(::probeHardwareDecoders)

    /** The same cached codec identity that owns every advertised limit for [mime]. */
    internal fun <T> createDecoder(
        mime: String,
        findLegacyDecoder: () -> String?,
        createByName: (String) -> T,
        createByType: (String) -> T,
    ): T = hardwareSelection.createDecoder(mime, findLegacyDecoder, createByName, createByType)

    /**
     * The `size` limit the largest usable *hardware* decoder for [mime] advertises. Null when
     * nothing usable exists or the probe fails (legacy behavior: advertise no limit to the Mac).
     * The selected codec is cached per MIME and is also used for playback.
     *
     * Nominal, not achievable. Vendor decoders routinely advertise a `size` far above what their
     * `blocks-per-second` budget can sustain, and configuring above that budget succeeds and then
     * silently never outputs a frame. Prefer [maxStreamSize] for anything the Mac will encode.
     */
    fun nominalMaxDecodeSize(mime: String): Pair<Int, Int>? = hardwareSelection.nominalMaxDecodeSize(mime)

    /** Keep the codec name with its capabilities instead of discarding the playback identity. */
    private fun probeHardwareDecoders(mime: String): List<HardwareDecoderProfile> =
        MediaCodecList(MediaCodecList.ALL_CODECS)
            .codecInfos
            .asSequence()
            .filter { isUsableHardwareDecoder(it, mime) }
            .mapNotNull { info ->
                try {
                    val codecCaps = info.getCapabilitiesForType(mime)
                    val caps = codecCaps.videoCapabilities ?: return@mapNotNull null
                    HardwareDecoderProfile(
                        info.name,
                        caps.supportedWidths.upper,
                        caps.supportedHeights.upper,
                        codecCaps::isFeatureRequired,
                    ) { width, height, rate -> caps.areSizeAndRateSupported(width, height, rate) }
                } catch (_: Exception) {
                    null
                }
            }.toList()

    private const val BLOCK_ALIGN = 16

    /**
     * Frame rate the advertised stream limit is measured at. The client cannot know the Mac's
     * frame-rate setting when it advertises (that arrives later), and measuring at the panel's
     * peak rate would shrink the picture on 120/144 Hz tablets that stream at the 60 Hz default.
     * The Mac scales the limit's area by 60/fps when it streams faster than this, so both sides
     * must agree on the number (see CodecLimits.scaleLimit on the Mac). A separate optional
     * limit checked at HIGH_REFRESH_FPS allows newer hosts to avoid that estimate at 120 FPS.
     */
    const val REFERENCE_FPS = 60
    const val HIGH_REFRESH_FPS = 120

    /**
     * The largest frame the Mac should ever encode for us: no larger than the panel can show, and
     * within what the decoder sustains at [fps]. Null when no usable decoder exists or the probe
     * fails, which leaves the legacy "advertise nothing" behavior in place.
     *
     * The panel is the upper bound because anything above it is downscaled on arrival anyway, so
     * spending decode budget there buys nothing. [MediaCodecInfo.VideoCapabilities.areSizeAndRateSupported]
     * is the check that consults `blocks-per-second`, which [nominalMaxDecodeSize] misses. Shrinks
     * stepwise rather than solving directly because the budget counts aligned macroblocks.
     */
    fun maxStreamSize(
        mime: String,
        panelWidth: Int,
        panelHeight: Int,
        fps: Int,
    ): Pair<Int, Int>? = hardwareSelection.maxStreamSize(mime, panelWidth, panelHeight, fps)

    /** Pure selection logic so native-size and fallback behavior can be tested without a device. */
    internal fun selectStreamSize(
        panelWidth: Int,
        panelHeight: Int,
        maxWidth: Int,
        maxHeight: Int,
        fps: Int,
        supportsSizeAndRate: (Int, Int, Double) -> Boolean,
    ): Pair<Int, Int>? {
        if (panelWidth <= 0 || panelHeight <= 0) return null
        val rate = fps.coerceAtLeast(1).toDouble()

        // Decoder capability checks already enforce its actual alignment. Preserve the native
        // size when supported instead of forcing every tablet onto a 16-pixel grid. Keep even
        // dimensions for the Mac's 4:2:0 capture path and retain the existing fallback otherwise.
        if (panelWidth in 256..maxWidth && panelHeight in 256..maxHeight &&
            panelWidth % 2 == 0 && panelHeight % 2 == 0
        ) {
            val nativeSupported =
                try {
                    supportsSizeAndRate(panelWidth, panelHeight, rate)
                } catch (_: IllegalArgumentException) {
                    false
                } catch (_: Exception) {
                    return null
                }
            if (nativeSupported) return panelWidth to panelHeight
        }

        var w = panelWidth.coerceAtMost(maxWidth)
        var h = panelHeight.coerceAtMost(maxHeight)
        val aspect = panelWidth.toDouble() / panelHeight.toDouble()

        repeat(40) {
            val alignedW = (w / BLOCK_ALIGN) * BLOCK_ALIGN
            val alignedH = (h / BLOCK_ALIGN) * BLOCK_ALIGN
            if (alignedW < 256 || alignedH < 256) return null
            val supported =
                try {
                    supportsSizeAndRate(alignedW, alignedH, rate)
                } catch (_: IllegalArgumentException) {
                    false
                } catch (_: Exception) {
                    return null
                }
            if (supported) return alignedW to alignedH
            w = (w * 0.95).toInt()
            h = (w / aspect).toInt()
        }
        return null
    }
}
