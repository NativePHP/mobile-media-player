package com.nativephp.plugins.media_player.ui

import android.content.Context
import android.content.ContextWrapper
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.ui.nativerender.NativeUINode
import com.nativephp.plugins.media_player.MediaPlayerManager

/**
 * Renderer for the `video_player` element type. Registered by the generated
 * `PluginRendererRegistration` via `NativeRendererRegistry.register`
 * (declared under `components[].android_renderer` in the plugin manifest).
 *
 * The incoming `modifier` carries the element's layout (width / height /
 * aspect) resolved by core, so the renderer only draws the video surface.
 *
 * On prepare, the VideoView's underlying MediaPlayer is adopted by
 * MediaPlayerManager so the PHP `MediaPlayer` facade (pause / resume / seek /
 * volume / status) drives on-screen playback, and PlaybackEnded /
 * PlaybackError events fire for element playback too. With `controls=false`
 * a bare surface renders — developers overlay their own Element UI.
 */
object VideoPlayerRenderer {
    @Composable
    fun Render(node: NativeUINode, modifier: Modifier) {
        val p = node.props
        val src = p.getString("src")
        val controls = p.getBool("controls", true)
        val autoplay = p.getBool("autoplay")
        val loop = p.getBool("loop")
        val muted = p.getBool("muted")

        if (src.isNotEmpty()) {
            AndroidView(
                modifier = modifier,
                factory = { context ->
                    VideoView(context).apply {
                        if (controls) {
                            val controller = MediaController(context)
                            controller.setAnchorView(this)
                            setMediaController(controller)
                        }
                    }
                },
                update = { view ->
                    // Only (re)load when the source actually changed — update
                    // runs on every recomposition.
                    if (view.tag != src) {
                        view.tag = src

                        view.setOnPreparedListener { mp ->
                            mp.isLooping = loop
                            if (muted) {
                                mp.setVolume(0f, 0f)
                            }

                            MediaPlayerManager.adoptElementPlayback(
                                view = view,
                                player = mp,
                                sourceToPlay = src,
                                activity = findActivity(view.context),
                                playing = autoplay
                            )

                            if (autoplay) {
                                view.start()
                            } else {
                                // Render the first frame instead of a black surface
                                view.seekTo(1)
                            }
                        }
                        view.setOnCompletionListener {
                            MediaPlayerManager.onElementCompleted(src)
                        }
                        view.setOnErrorListener { _, what, extra ->
                            MediaPlayerManager.onElementError(src, "MediaPlayer error what=$what extra=$extra")
                            true
                        }

                        view.setVideoURI(MediaPlayerManager.resolveUri(src))
                    }
                }
            )
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
