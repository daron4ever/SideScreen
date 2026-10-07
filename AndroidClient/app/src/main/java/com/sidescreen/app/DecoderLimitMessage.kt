package com.sidescreen.app

/** High-bit payload bytes let older hosts skip an unknown message without losing framing. */
internal fun encodeDecoderLimitPayload(
    width: Int,
    height: Int,
): ByteArray? {
    if (width < 256 || height < 256) return null
    val w = width.coerceAtMost(16383)
    val h = height.coerceAtMost(16383)
    return byteArrayOf(
        (0x80 or ((w shr 7) and 0x7F)).toByte(),
        (0x80 or (w and 0x7F)).toByte(),
        (0x80 or ((h shr 7) and 0x7F)).toByte(),
        (0x80 or (h and 0x7F)).toByte(),
    )
}
