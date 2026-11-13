package com.nativephp.plugins.media_player

import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.media3.common.Player
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import java.lang.ref.WeakReference

/**
 * Hosts MediaPlayerManager's session, so headless playback keeps going
 * when the app is in the background or the screen is locked.
 *
 * Media3 does the rest: while the session's player plays, it posts the
 * media notification (which is also what the lock screen shows) and
 * runs this service in the foreground; when playback pauses it lets the
 * service drop out of the foreground, so the user can swipe the
 * notification away.
 *
 * The manager owns the player and session. This service only shows
 * them to the system, and never releases them itself.
 */
class MediaPlaybackService : MediaSessionService() {

    companion object {
        private const val TAG = "MediaPlaybackService"

        private var running: WeakReference<MediaPlaybackService>? = null

        /**
         * Hand [session] to the service, starting it if needed. Called
         * from play(), which PHP drives while the app is in the
         * foreground, so a plain startService is allowed.
         */
        fun attach(context: Context, session: MediaSession) {
            val service = running?.get()
            if (service != null) {
                service.addSession(session)
                return
            }

            try {
                context.startService(Intent(context, MediaPlaybackService::class.java))
            } catch (e: Exception) {
                // Started from the background: the session still works in
                // the app, it only misses the system controls.
                Log.e(TAG, "❌ Could not start the playback service: ${e.message}")
            }
        }

        /** Take [session] away from the service and stop it. */
        fun detach(context: Context?, session: MediaSession) {
            running?.get()?.removeSession(session)

            if (context != null) {
                context.stopService(Intent(context, MediaPlaybackService::class.java))
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        running = WeakReference(this)

        // play() may have built the session before the service was up.
        MediaPlayerManager.currentSession()?.let { addSession(it) }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        MediaPlayerManager.currentSession()

    /**
     * The user swiped the app away. Keep playing if something is playing,
     * otherwise there is nothing for the notification to control.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = MediaPlayerManager.currentSession()?.player

        if (player == null || !player.playWhenReady || player.playbackState == Player.STATE_ENDED) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        if (running?.get() === this) {
            running = null
        }

        // Sessions stay with the manager; only stop tracking them here.
        sessions.forEach { removeSession(it) }

        super.onDestroy()
    }
}
