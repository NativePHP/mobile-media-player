# Media Player Plugin for NativePHP Mobile

Audio/video playback for NativePHP Mobile: a shared background player driven from PHP, a full-screen system player, and an inline `<video-player>` element for native (Edge) views.

## Overview

The plugin provides three ways to play media:

- **Shared player** — `MediaPlayer::play()` plays audio or video sources app-wide (AVPlayer on iOS, MediaPlayer on Android) with pause/resume/seek/volume control from PHP.
- **Full-screen presentation** — `MediaPlayer::present()` opens the system player UI (AVPlayerViewController on iOS, a dedicated full-screen activity on Android); the user dismisses it natively.
- **Inline `<video-player>` element** — a video surface for native UI views, rendered as SwiftUI `VideoPlayer` (AVKit) on iOS and a `VideoView` inside Compose on Android.

## Installation

```shell
composer require nativephp/mobile-media-player
```

Don't forget to register the plugin:

```shell
php artisan native:plugin:register nativephp/mobile-media-player
```

## Usage

### Shared player (PHP)

```php
use NativePHP\MediaPlayer\Facades\MediaPlayer;

// Play a bundled file, storage path, or URL
MediaPlayer::play(storage_path('app/theme.mp3'));

// With options
MediaPlayer::play('https://example.com/stream.mp3', [
    'loop' => true,
    'volume' => 0.5,
]);

// Transport controls
MediaPlayer::pause();
MediaPlayer::resume();
MediaPlayer::seek(42.5);        // seconds
MediaPlayer::setVolume(0.8);    // 0.0 – 1.0
MediaPlayer::stop();            // stops and releases the player

// Poll playback state
$status = MediaPlayer::getStatus();
// ['state' => 'playing', 'position' => 12.3, 'duration' => 180.0, 'source' => '...']
```

`play()` and `present()` return `false` when the source can't be started (or when
running outside the native runtime).

### Full-screen system player

```php
MediaPlayer::present(storage_path('app/videos/intro.mp4'));
```

### Inline video in native views

```blade
<video-player :src="$video['path']" controls class="w-full aspect-video rounded-2xl"/>
```

Attributes:

| Attribute  | Default | Description |
|------------|---------|-------------|
| `src`      | —       | File path or URL |
| `controls` | `true`  | Show native transport chrome |
| `autoplay` | `false` | Play while the surface is on screen (see below) |
| `loop`     | `false` | Restart when playback ends |
| `muted`    | `false` | Start muted |
| `fit`      | `1`     | How the frame fits the surface: `1` contain, `2` cover, `3` fill. The `object-contain`, `object-cover` and `object-fill` classes set it too |
| `poster`   | —       | Image (URL or path) shown until the player has a frame to draw, fitted like the video |

Sizing follows the element's layout props (`width`/`height`/`aspect` classes), like `Image`.

Each surface owns its own player, prepared as soon as the surface exists. With
`autoplay` it plays while at least 45% of it is inside its scroll view and
pauses below that, rewinding only once it is fully off screen. Outside a scroll
view it counts as visible and just plays. That is all a swipe feed needs: the
page on screen plays, its neighbours sit buffered and silent, and the hand-off
happens at the crossover. Pair it with mobile-ui's `<native:pager>` for the
TikTok-style feed.

The surface on screen is the one the `MediaPlayer` facade drives, so
`MediaPlayer::pause()` from a tap handler pauses the video the user is looking
at without naming it. With a `poster` and `controls=false`, the first play waits
until the layer holds a frame, so the still never cuts to a clip already in
motion.

With `controls=false` you get a bare video surface — overlay your own Element UI
and drive playback through the `MediaPlayer` facade:

```blade
<stack class="w-full h-full">
    <video-player :src="$src" poster="{{ $poster }}" :controls="false" autoplay loop class="w-full h-full object-cover"/>
    <button @press="togglePlayback" icon="pause.fill" class="absolute bottom-2 right-2"/>
</stack>
```

### Building the element from PHP

```php
use NativePHP\MediaPlayer\Elements\VideoPlayer;

VideoPlayer::make($path)
    ->controls(false)
    ->autoplay()
    ->loop()
    ->muted()
    ->fit(2)
    ->poster($posterUrl);
```

## Events

### `PlaybackEnded`

Fired when the shared player reaches the end of the source.

**Payload:** `string $source`

```php
use Native\Mobile\Attributes\OnNative;
use NativePHP\MediaPlayer\Events\PlaybackEnded;

#[OnNative(PlaybackEnded::class)]
public function handlePlaybackEnded(string $source)
{
    $this->playNext();
}
```

### `PlaybackError`

Fired when the shared player fails to load or play a source.

**Payload:** `string $source`, `string $message`

```php
use Native\Mobile\Attributes\OnNative;
use NativePHP\MediaPlayer\Events\PlaybackError;

#[OnNative(PlaybackError::class)]
public function handlePlaybackError(string $source, string $message)
{
    $this->status = "Playback failed: {$message}";
}
```

## Status values

`MediaPlayer::getStatus()['state']` is one of: `idle`, `playing`, `paused`.

## Testing

The plugin extends the NativePHP testing suite with playback-specific helpers, so your app tests can fake and assert media activity without knowing any bridge internals:

```php
use Native\Mobile\Testing\Native;

it('plays the selected track', function () {
    Native::fakeBridge();

    Native::test(NowPlaying::class)
        ->tap('Play')
        ->assertPlayed('https://example.com/stream.mp3');
});

it('shows where playback is', function () {
    Native::fakeBridge()->withPlaybackStatus('playing', position: 12.0, duration: 180.0);

    Native::test(NowPlaying::class)
        ->call('refresh')
        ->assertSee('0:12 / 3:00');
});

it('pauses, seeks, and stops', function () {
    Native::fakeBridge();

    Native::test(NowPlaying::class)
        ->tap('Pause')->assertPaused()
        ->tap('Skip forward')->assertSeeked(30.0)
        ->tap('Stop')->assertStopped();
});
```

### Helpers

- `withPlaybackStatus(string $state = 'playing', float $position = 0.0, float $duration = 0.0, ?string $source = null)` — script the status `getStatus()` reports. `$state` is one of `idle`, `playing`, `paused`.
- `assertPlayed(?string $source = null)` — assert playback was started, or exactly `$source` (a path or URL) when given.
- `assertPaused()` — assert playback was paused.
- `assertStopped()` — assert playback was stopped and the player released.
- `assertSeeked(?float $to = null)` — assert a seek happened, or to exactly `$to` seconds when given.
- `assertNothingPlayed()` — assert no playback was started.

The helpers are available on `Native::fakeBridge()` and chain directly off `Native::test(...)`. They register automatically while running tests (requires a core with a macroable FakeBridge; on older cores they simply don't register).

## Platform Support

- **iOS:** 16.0+ (AVPlayer / AVKit)
- **Android:** API 26+ (Media3 ExoPlayer for `video_player`; `android.media.MediaPlayer` for headless playback)

## Notes

- One thing plays at a time: `play()` replaces whatever is playing, and a
  `video_player` that comes on screen takes over from the previous one. Each
  surface keeps its own player, so a feed of pages never fights over one.
- Remote URLs require network access; local paths must be readable by the app
  (e.g. `storage_path()` or bundled assets).
- No runtime permissions are required.
