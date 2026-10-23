package com.rohankanjani.lull.bedjetkit

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/**
 * Two phones share one BedJet by handing over: the phone that wants it briefly advertises a request,
 * and the phone holding it disconnects when it sees that request.
 */
object Handoff {
    /**
     * Requests are specific to one BedJet, so a neighbour's phone looking for theirs is ignored.
     * Derived exactly as the iOS app derives it, so iPhones and Android phones hand over to each other.
     */
    fun uuid(deviceName: String): UUID {
        val bytes = MessageDigest.getInstance("SHA-256").digest("lull.handoff.$deviceName".encodeToByteArray()).copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long)
    }
}
