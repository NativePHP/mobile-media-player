package com.nativephp.plugins.media_player

import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.VideoView
import androidx.appcompat.app.AppCompatActivity

/**
 * Full-screen playback Activity used by `MediaPlayer.Present`. Hosts a
 * VideoView with system transport controls (MediaController); finishes when
 * playback completes, errors, or the user navigates back — mirroring the
 * dedicated-Activity pattern the doom-game plugin uses (declared in the
 * plugin manifest under `android.activities`).
 */
class FullscreenPlayerActivity : AppCompatActivity() {

    private lateinit var videoView: VideoView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val source = intent.getStringExtra(EXTRA_SOURCE)
        if (source.isNullOrEmpty()) {
            finish()
            return
        }

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        videoView = VideoView(this)

        val container = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(
                videoView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER
                )
            )
        }

        setContentView(container)

        val controller = MediaController(this)
        controller.setAnchorView(videoView)
        videoView.setMediaController(controller)

        videoView.setOnCompletionListener {
            finish()
        }
        videoView.setOnErrorListener { _, what, extra ->
            MediaPlayerManager.onElementError(source, "MediaPlayer error what=$what extra=$extra")
            finish()
            true
        }
        videoView.setOnPreparedListener {
            videoView.start()
        }

        videoView.setVideoURI(MediaPlayerManager.resolveUri(source))
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::videoView.isInitialized) {
            videoView.stopPlayback()
        }
    }

    companion object {
        const val EXTRA_SOURCE = "source"
    }
}
