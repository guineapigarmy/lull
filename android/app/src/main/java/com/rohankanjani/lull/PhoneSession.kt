package com.rohankanjani.lull

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.android.gms.tasks.Task
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Lull on the phone, as the watch sees it. The watch has no Bluetooth link of its own to the BedJet, so this hands it
 * what the widgets show and runs the errands it asks for. Asking starts Lull in the background when it isn't running,
 * which is the only time Lull reaches a BedJet while it's off screen, and it lets go again as soon as it's done.
 *
 * Everything goes straight to the watch over the Wearable Data Layer's messages, never through Google's servers.
 */
object PhoneSession {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Everything for the watch, in the order it was made, so the watch never shows an older snapshot over a newer one. */
    private val outbox = Outbox(scope)

    /** What the widgets show, encoded, kept for the reply that follows an errand. */
    @Volatile private var latest: ByteArray? = null
    /** Counts snapshots made, so one waiting its turn is skipped once a newer one is on its way. */
    private val made = AtomicLong()

    /** Hands every watch with Lull what the widgets show. A watch that's away gets the next one. */
    fun send(context: Context, snapshot: WidgetSnapshot) {
        val data = lullJson.encodeToString(WidgetSnapshot.serializer(), snapshot).toByteArray()
        latest = data
        val number = made.incrementAndGet()
        val app = context.applicationContext
        outbox.post {
            // Starting a night changes what the widgets show several times in a second; only the last needs to go.
            if (number != made.get()) return@post
            for (watch in watches(app)) Wearable.getMessageClient(app).sendMessage(watch, WatchMessages.SNAPSHOT, data).awaited()
        }
    }

    /**
     * Says how an errand went, after what the widgets show now, so the watch never shows the moment before. A refresh
     * only hands over what the widgets show.
     */
    suspend fun reply(context: Context, watch: String, command: WatchCommand, reply: WatchReply) {
        outbox.postAndWait {
            val messages = Wearable.getMessageClient(context)
            latest?.let { messages.sendMessage(watch, WatchMessages.SNAPSHOT, it).awaited() }
            if (command.isAnswered) messages.sendMessage(watch, WatchMessages.REPLY, reply.data).awaited()
        }
    }

    private suspend fun watches(context: Context): List<String> =
        Wearable.getCapabilityClient(context)
            .getCapability(WatchMessages.WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE).awaited()
            .nodes.map { it.id }
}

/** Takes errands from the watch, even while Lull is closed, and hands each to an [ErrandWorker]. */
class PhoneSessionService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != WatchMessages.COMMAND) return
        if (WatchCommand.from(event.data) == null) {
            val reply = WatchReply.failed("Update Lull on your phone to use it from your watch.")
            Wearable.getMessageClient(this).sendMessage(event.sourceNodeId, WatchMessages.REPLY, reply.data)
            return
        }
        // Expedited work runs at once, and stays within what Android lets an app do in the background.
        val work = OneTimeWorkRequestBuilder<ErrandWorker>()
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setInputData(
                Data.Builder()
                    .putByteArray(ErrandWorker.COMMAND, event.data)
                    .putString(ErrandWorker.WATCH, event.sourceNodeId)
                    .putLong(ErrandWorker.ASKED_AT, System.currentTimeMillis())
                    .build(),
            )
            .build()
        WorkManager.getInstance(this).enqueue(work)
    }
}

/** Runs one errand from the watch on the app's model, then says how it went. */
class ErrandWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val command = inputData.getByteArray(COMMAND)?.let(WatchCommand::from) ?: return Result.failure()
        val watch = inputData.getString(WATCH) ?: return Result.failure()
        if (isTooLate(inputData.getLong(ASKED_AT, 0), System.currentTimeMillis())) {
            // Said now, in the watch's own words for it, rather than leaving the watch to run out its wait.
            PhoneSession.reply(applicationContext, watch, command, WatchReply.failed(WatchMessages.TOO_LATE))
            return Result.success()
        }
        val reply = withContext(Dispatchers.Main) {
            (applicationContext as LullApplication).model().runErrand(command)
        }
        PhoneSession.reply(applicationContext, watch, command, reply)
        return Result.success()
    }

    companion object {
        const val COMMAND = "command"
        const val WATCH = "watch"
        const val ASKED_AT = "askedAt"

        /**
         * How soon an errand has to start. Expedited work starts within a second or two; one that waited longer, once
         * Android's allowance for it ran out, couldn't reach the BedJet and finish before the watch gives up, and would start
         * a night while the watch says Lull didn't answer.
         */
        const val START_WITHIN = 10_000L

        fun isTooLate(askedAt: Long, now: Long): Boolean = now - askedAt > START_WITHIN
    }
}

/** Waits for a Play services task without a library for it. */
suspend fun <T> Task<T>.awaited(): T = suspendCancellableCoroutine { waiting ->
    addOnSuccessListener { waiting.resume(it) }
    addOnFailureListener { waiting.resumeWithException(it) }
    addOnCanceledListener { waiting.cancel() }
}
