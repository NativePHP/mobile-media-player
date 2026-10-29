package com.nativephp.plugins.media_player.ui

import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil3.ImageLoader
import coil3.compose.AsyncImage
import coil3.gif.AnimatedImageDecoder
import coil3.gif.GifDecoder
import com.nativephp.mobile.ui.nativerender.NativeUINode

/**
 * Renderer for the `animated_image` element type. Registered by the generated
 * `PluginRendererRegistration` via `NativeRendererRegistry.register`
 * (declared under `components[].android_renderer` in the plugin manifest).
 *
 * Core's stock `image` renderer uses Coil's default decoders, which produce a
 * single still frame for GIF / APNG / animated WebP. This one registers Coil's
 * animated decoder, so the same formats animate.
 *
 * Unlike `video_player` this allocates no MediaPlayer and no hardware decoder
 * session, so a scrolling list can hold many of these at once.
 *
 * The incoming `modifier` carries the element's layout (width / height /
 * aspect) resolved by core, so the renderer only draws the image surface.
 *
 * `loop` is iOS-only: Android's animated decoders honour the loop count baked
 * into the file, which for GIFs from the wild is almost always infinite.
 */
object AnimatedImageRenderer {
    @Composable
    fun Render(node: NativeUINode, modifier: Modifier) {
        val p = node.props
        val src = p.getString("src")
        val fit = p.getInt("fit", 1)
        val alt = p.getString("alt")
        val autoplay = p.getBool("autoplay", true)

        if (src.isEmpty()) {
            return
        }

        val context = LocalContext.current

        // One loader per context, shared by every animated_image on screen.
        // Without autoplay we want Coil's default decoders, which stop at the
        // first frame — exactly the paused resting state.
        val imageLoader = remember(context, autoplay) {
            if (!autoplay) {
                ImageLoader(context)
            } else {
                ImageLoader.Builder(context)
                    .components {
                        // ImageDecoder (API 28+) handles GIF, APNG and
                        // animated WebP; the older GifDecoder covers GIF back
                        // to API 26, which is this plugin's floor.
                        if (Build.VERSION.SDK_INT >= 28) {
                            add(AnimatedImageDecoder.Factory())
                        } else {
                            add(GifDecoder.Factory())
                        }
                    }
                    .build()
            }
        }

        AsyncImage(
            model = src,
            // `alt` marks the image as meaningful; without it the image stays
            // decorative (silent for TalkBack) — same contract as `image`.
            contentDescription = alt.ifEmpty { null },
            imageLoader = imageLoader,
            modifier = modifier,
            contentScale = resolveContentScale(fit)
        )
    }
}

private fun resolveContentScale(fit: Int): ContentScale {
    return when (fit) {
        0 -> ContentScale.None
        1 -> ContentScale.Fit
        2 -> ContentScale.Crop
        3 -> ContentScale.FillBounds
        else -> ContentScale.Fit
    }
}
