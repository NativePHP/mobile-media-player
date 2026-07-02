## nativephp/media-player

Media player plugin for NativePHP Mobile: shared audio/video playback, full-screen presentation, and an inline `<video-player>` element for native (Edge) views.

### Shared Player (PHP)

One app-wide player (AVPlayer on iOS, MediaPlayer on Android). `play()` replaces whatever is currently playing.

@verbatim
<code-snippet name="Playing Media" lang="php">
use NativePHP\MediaPlayer\Facades\MediaPlayer;

// File path or URL; returns false if the source can't start
MediaPlayer::play(storage_path('app/theme.mp3'), ['loop' => true, 'volume' => 0.5]);

MediaPlayer::pause();
MediaPlayer::resume();
MediaPlayer::seek(42.5);      // seconds
MediaPlayer::setVolume(0.8);  // 0.0 - 1.0
MediaPlayer::stop();          // stop and release

$status = MediaPlayer::getStatus();
// ['state' => 'playing'|'paused'|'idle', 'position' => float, 'duration' => float, 'source' => ?string]
</code-snippet>
@endverbatim

### Full-Screen System Player

@verbatim
<code-snippet name="Full-Screen Playback" lang="php">
use NativePHP\MediaPlayer\Facades\MediaPlayer;

// AVPlayerViewController (iOS) / full-screen activity (Android); user dismisses natively
MediaPlayer::present(storage_path('app/videos/intro.mp4'));
</code-snippet>
@endverbatim

### Inline Video Element (native/Edge views)

@verbatim
<code-snippet name="Video Player Element" lang="blade">
<video-player :src="$video['path']" controls class="w-full aspect-video rounded-2xl"/>

{{-- Bare surface: overlay your own UI, drive via the MediaPlayer facade --}}
<video-player :src="$src" :controls="false" autoplay muted class="w-full h-full"/>
</code-snippet>
@endverbatim

Attributes: `src` (path/URL), `controls` (default true), `autoplay` (default false), `loop` (default false), `muted` (default false). Sizing follows layout classes (`w-*`/`h-*`/`aspect-*`) like `Image`.

### Handling Playback Events

@verbatim
<code-snippet name="Playback Events" lang="php">
use Native\Mobile\Attributes\OnNative;
use NativePHP\MediaPlayer\Events\PlaybackEnded;
use NativePHP\MediaPlayer\Events\PlaybackError;

#[OnNative(PlaybackEnded::class)]
public function handlePlaybackEnded(string $source)
{
    $this->playNext();
}

#[OnNative(PlaybackError::class)]
public function handlePlaybackError(string $source, string $message)
{
    $this->status = "Playback failed: {$message}";
}
</code-snippet>
@endverbatim

### Notes

- **iOS:** 16.0+ · **Android:** API 26+ · no runtime permissions required
- One shared player — `play()` replaces the current source
- Local paths must be readable by the app (`storage_path()` or bundled assets)
