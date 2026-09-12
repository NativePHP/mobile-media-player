package com.nativephp.plugins.media_player.ui

import android.content.Context
import android.content.ContextWrapper
import android.graphics.Color
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.fragment.app.FragmentActivity
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.nativephp.mobile.ui.nativerender.LocalReelPageActive
import com.nativephp.mobile.ui.nativerender.NativeUINode
import com.nativephp.plugins.media_player.MediaPlayerManager

/**
 * Renderer for the `video_player` element type. Registered by the generated
 * `PluginRendererRegistration` via `NativeRendererRegistry.register`
 * (declared under `components[].android_renderer` in the plugin manifest).
 *
 * One Media3 `ExoPlayer` per node, shown through a `PlayerView`. The
 * incoming `modifier` carries the element's layout (width / height /
 * aspect) resolved by core, so the renderer only draws the surface.
 *
 * Inside a paged container (mobile-ui's `reel`) `LocalReelPageActive`
 * is non-null: the visible page plays, its pre-composed neighbours stay
 * prepared (first frame + initial buffer ready) but paused and rewound,
 * so a swipe lands on video that starts instantly. Outside a pager the
 * local is null and `autoplay` alone decides.
 *
 * The playing (or, outside a pager, the only) surface is adopted by
 * `MediaPlayerManager`, so the PHP `MediaPlayer` facade drives it and
 * PlaybackEnded / PlaybackError fire for element playback too.
 */
@androidx.annotation.OptIn(UnstableApi::class)
object VideoPlayerRenderer {
    @Composable
    fun Render(node: NativeUINode, modifier: Modifier) {
        val p = node.props
        val src = p.getString("src")
        val controls = p.getBool("controls", true)
        val autoplay = p.getBool("autoplay")
        val loop = p.getBool("loop")
        val muted = p.getBool("muted")

        if (src.isEmpty()) {
            return
        }

        val pageActive = LocalReelPageActive.current
        val context = LocalContext.current
        val activity = remember(context) { findActivity(context) }
        val currentSrc = rememberUpdatedState(src)

        val player = remember(context) {
            ExoPlayer.Builder(context)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .setUsage(C.USAGE_MEDIA)
                        .build(),
                    /* handleAudioFocus = */ true
                )
                .build()
        }

        DisposableEffect(player) {
            val listener = object : Player.Listener {
                override fun onPlaybackStateChanged(playbackState: Int) {
                    if (playbackState == Player.STATE_ENDED && MediaPlayerManager.isAdopted(player)) {
                        MediaPlayerManager.onElementCompleted(currentSrc.value)
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    if (MediaPlayerManager.isAdopted(player)) {
                        MediaPlayerManager.onElementError(
                            currentSrc.value,
                            error.message ?: "ExoPlayer error ${error.errorCodeName}"
                        )
                    }
                }
            }
            player.addListener(listener)
            onDispose {
                player.removeListener(listener)
                MediaPlayerManager.releaseElementPlayback(player)
                player.release()
            }
        }

        LaunchedEffect(player, src) {
            player.setMediaItem(MediaItem.fromUri(MediaPlayerManager.resolveUri(src)))
            player.prepare()
        }

        LaunchedEffect(player, loop) {
            player.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        }

        LaunchedEffect(player, muted) {
            player.volume = if (muted) 0f else 1f
        }

        // null  → not in a pager: autoplay decides.
        // true  → the settled page: adopt + honour autoplay.
        // false → a pre-composed neighbour: stay prepared, paused, at 0.
        LaunchedEffect(player, src, pageActive, autoplay) {
            if (pageActive == false) {
                player.pause()
                player.seekTo(0)
                MediaPlayerManager.releaseElementPlayback(player)
                return@LaunchedEffect
            }

            player.playWhenReady = autoplay
            MediaPlayerManager.adoptElementPlayback(
                player = player,
                sourceToPlay = src,
                activity = activity,
                playing = autoplay
            )
        }

        AndroidView(
            modifier = modifier,
            factory = { ctx ->
                PlayerView(ctx).apply {
                    useController = controls
                    setShutterBackgroundColor(Color.BLACK)
                    setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
                    this.player = player
                }
            },
            update = { view ->
                view.useController = controls
                if (view.player !== player) {
                    view.player = player
                }
            }
        )
    }

    /**
     * Unwrap a Compose context to its hosting FragmentActivity (for event
     * dispatch through NativeActionCoordinator).
     */
    private fun findActivity(context: Context): FragmentActivity? {
        var current: Context = context
        while (current is ContextWrapper) {
            if (current is FragmentActivity) {
                return current
            }
            current = current.baseContext
        }
        return null
    }
}
