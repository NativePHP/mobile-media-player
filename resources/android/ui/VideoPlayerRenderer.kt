package com.nativephp.plugins.media_player.ui

import android.content.Context
import android.content.ContextWrapper
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
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
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.nativephp.mobile.ui.nativerender.NativeUINode
import com.nativephp.plugins.media_player.MediaPlayerManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URL

/**
 * Renderer for the `video_player` element type. Registered by the generated
 * `PluginRendererRegistration` via `NativeRendererRegistry.register`
 * (declared under `components[].android_renderer` in the plugin manifest).
 *
 * One Media3 `ExoPlayer` per node, shown through a `PlayerView`. The
 * incoming `modifier` carries the element's layout (width / height /
 * aspect) resolved by core, so the renderer only draws the surface.
 *
 * Each surface is prepared as soon as it is composed so a page that
 * scrolls in starts instantly. `autoplay` means "play while mostly on
 * screen": the surface measures how much of it is inside the window,
 * plays at half or more, pauses below that, and rewinds only once it is
 * fully off screen — a feed pager needs no coordination, and nothing in
 * core mediates.
 *
 * Nothing happens before the first measurement: a freshly composed
 * neighbour that assumed it was visible would adopt the shared player
 * slot and pause the page actually being watched.
 *
 * The playing surface is adopted by `MediaPlayerManager`, so the PHP
 * `MediaPlayer` facade drives it and PlaybackEnded / PlaybackError fire
 * for element playback too.
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
        val poster = p.getString("poster")
        // 1 contain (default), 2 cover, 3 fill — the Image `fit` contract.
        val fit = p.getInt("fit", 1)
        val resizeMode = when (fit) {
            2 -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
            3 -> AspectRatioFrameLayout.RESIZE_MODE_FILL
            else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
        }

        if (src.isEmpty()) {
            return
        }

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

        // Fraction of the surface inside the window; null until measured.
        var visibleFraction by remember { mutableStateOf<Float?>(null) }
        // Hand-off at the crossover, like Instagram's feed: play from ~45%
        // on screen, pause below it — one threshold for both directions.
        val shown: Boolean? = visibleFraction?.let { f -> f >= 0.45f }
        val offscreen = visibleFraction == 0f

        LaunchedEffect(player, src, shown, autoplay) {
            when (shown) {
                null -> return@LaunchedEffect
                true -> {
                    player.playWhenReady = autoplay
                    MediaPlayerManager.adoptElementPlayback(
                        player = player,
                        sourceToPlay = src,
                        activity = activity,
                        playing = autoplay
                    )
                }
                false -> {
                    player.pause()
                    MediaPlayerManager.releaseElementPlayback(player)
                }
            }
        }

        // Rewind only once fully off screen, so it starts clean when it
        // comes back and the rewind is never seen mid-swipe.
        LaunchedEffect(player, offscreen) {
            if (offscreen) player.seekTo(0)
        }

        // Poster on top until the first frame renders — a page then shows
        // its still the instant it exists instead of black.
        var firstFrame by remember(player, src) { mutableStateOf(false) }
        DisposableEffect(player, src) {
            val listener = object : Player.Listener {
                override fun onRenderedFirstFrame() { firstFrame = true }
            }
            player.addListener(listener)
            onDispose { player.removeListener(listener) }
        }
        val posterBitmap = remember(poster) { mutableStateOf<android.graphics.Bitmap?>(null) }
        LaunchedEffect(poster) {
            posterBitmap.value = if (poster.isEmpty()) null else withContext(Dispatchers.IO) {
                runCatching {
                    val uri = MediaPlayerManager.resolveUri(poster)
                    if (uri.scheme == "file" || uri.scheme == null) {
                        BitmapFactory.decodeFile(uri.path)
                    } else {
                        URL(poster).openStream().use { BitmapFactory.decodeStream(it) }
                    }
                }.getOrNull()
            }
        }

        Box(
            modifier = modifier.onGloballyPositioned { coords ->
                val size = coords.size
                if (size.width <= 0 || size.height <= 0) return@onGloballyPositioned
                val bounds = coords.boundsInWindow()
                val fraction = (bounds.width * bounds.height) / (size.width.toFloat() * size.height.toFloat())
                visibleFraction = fraction.coerceIn(0f, 1f)
            }
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = controls
                        setShutterBackgroundColor(Color.BLACK)
                        setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
                        this.resizeMode = resizeMode
                        this.player = player
                    }
                },
                update = { view ->
                    view.useController = controls
                    view.resizeMode = resizeMode
                    if (view.player !== player) {
                        view.player = player
                    }
                }
            )

            val bitmap = posterBitmap.value
            if (bitmap != null && !firstFrame) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = null,
                    contentScale = when (fit) {
                        2 -> ContentScale.Crop
                        3 -> ContentScale.FillBounds
                        else -> ContentScale.Fit
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
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
