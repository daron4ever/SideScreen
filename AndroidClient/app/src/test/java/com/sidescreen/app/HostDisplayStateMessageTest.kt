package com.sidescreen.app

import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HostDisplayStateMessageTest {
    @Test
    fun wireIdsMatchTheMacContractAndPayloadIsExactlyOneByte() {
        assertEquals(15, HostDisplayStateMessage.CLIENT_SUPPORTS_HOST_DISPLAY_STATE)
        assertEquals(16, HostDisplayStateMessage.SERVER_HOST_DISPLAY_STATE)
        val input = DataInputStream(ByteArrayInputStream(byteArrayOf(0, 1, 5)))
        assertFalse(HostDisplayStateMessage.readAwake(input))
        assertTrue(HostDisplayStateMessage.readAwake(input))
        assertEquals(5, input.readUnsignedByte())
    }

    @Test
    fun invalidStateRejectsTheMessageWithoutConsumingTheNextType() {
        for (invalid in listOf(2, 15, 16, 128, 255)) {
            val input = DataInputStream(ByteArrayInputStream(byteArrayOf(invalid.toByte(), 5)))
            try {
                HostDisplayStateMessage.readAwake(input)
                fail("Accepted invalid state $invalid")
            } catch (_: IOException) {
                assertEquals(5, input.readUnsignedByte())
            }
        }
    }

    @Test(expected = EOFException::class)
    fun truncatedStateIsRejected() {
        HostDisplayStateMessage.readAwake(DataInputStream(ByteArrayInputStream(byteArrayOf())))
    }
}
