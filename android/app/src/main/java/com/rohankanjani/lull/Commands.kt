package com.rohankanjani.lull

import android.content.Context
import android.content.Intent
import android.net.Uri

/** The app's tabs, which widgets, tiles and shortcuts open to. */
enum class LullTab {
    REMOTE, SCHEDULE, HISTORY;

    /** Opens Lull on this tab when a widget is tapped. */
    val link: String get() = "lull://${name.lowercase()}"

    companion object {
        fun from(link: String?): LullTab? = entries.firstOrNull { it.link == link }
    }
}

/**
 * Passes what a widget, tile or shortcut asked for to the app, which picks it up once its screens are ready.
 * Those all open the app, which may start before its screens are, so commands wait here until then.
 */
object AppCommands {
    sealed interface Command {
        data class Show(val tab: LullTab) : Command
        data object StartNight : Command
    }

    /** What a widget, tile or shortcut asks for by starting the app. */
    const val ACTION_START_NIGHT = "com.rohankanjani.lull.START_NIGHT"

    var handler: ((Command) -> Unit)? = null
        set(value) {
            field = value
            deliver()
        }

    private val pending = mutableListOf<Command>()

    fun send(command: Command) {
        pending += command
        deliver()
    }

    /** The command an intent that opened the app carries, if any. */
    fun from(intent: Intent?): Command? = when {
        intent == null -> null
        intent.action == ACTION_START_NIGHT -> Command.StartNight
        else -> LullTab.from(intent.dataString)?.let(Command::Show)
    }

    fun startNightIntent(context: Context): Intent =
        Intent(context, MainActivity::class.java).setAction(ACTION_START_NIGHT).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    fun openIntent(context: Context, tab: LullTab): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse(tab.link), context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    private fun deliver() {
        val handler = handler ?: return
        val commands = pending.toList()
        pending.clear()
        commands.forEach(handler)
    }
}
