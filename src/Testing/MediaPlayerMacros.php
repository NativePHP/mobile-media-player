<?php

namespace NativePHP\MediaPlayer\Testing;

use Native\Mobile\Testing\FakeBridge;
use PHPUnit\Framework\Assert;

/**
 * Media player test vocabulary for the NativePHP testing suite, registered
 * as FakeBridge macros so app tests read in playback terms instead of raw
 * bridge method strings:
 *
 *     Native::fakeBridge()->withPlaybackStatus('playing', position: 12.0, duration: 180.0);
 *
 *     Native::test(NowPlaying::class)
 *         ->tap('play')
 *         ->assertPlayed('https://example.com/stream.mp3');
 *
 * The shared player is otherwise fire-and-forget — pause/resume/stop/seek
 * return no value — so those flows get assert* vocabulary only. Playback
 * state is the one thing the app reads back (getStatus()), so it gets the
 * with* scripting helper.
 *
 * Registered by MediaPlayerServiceProvider when the app is running unit
 * tests on a core whose FakeBridge supports macros.
 */
class MediaPlayerMacros
{
    public static function register(): void
    {
        /**
         * Script the playback status that getStatus() reports. Defaults to a
         * playing player at the start of the timeline; pass position/duration/
         * source to describe where playback is. State is one of the values the
         * facade documents: idle, playing, paused.
         */
        FakeBridge::macro('withPlaybackStatus', function (
            string $state = 'playing',
            float $position = 0.0,
            float $duration = 0.0,
            ?string $source = null,
        ) {
            return $this->respondTo('MediaPlayer.GetStatus', [
                'state' => $state,
                'position' => $position,
                'duration' => $duration,
                'source' => $source,
            ]);
        });

        /**
         * Assert playback was started — any source, or exactly $source when
         * given (a file path or URL passed to MediaPlayer::play()).
         */
        FakeBridge::macro('assertPlayed', function (?string $source = null) {
            if ($source === null) {
                return $this->assertCalled('MediaPlayer.Play');
            }

            $played = array_map(
                fn (array $call) => $call['params']['source'] ?? '',
                $this->callsTo('MediaPlayer.Play')
            );

            Assert::assertContains(
                $source,
                $played,
                "Expected [{$source}] to be played. Played: "
                    .($played === [] ? '(nothing)' : '['.implode('], [', $played).']')
            );

            return $this;
        });

        /** Assert playback was paused (MediaPlayer::pause()). */
        FakeBridge::macro('assertPaused', function () {
            return $this->assertCalled('MediaPlayer.Pause');
        });

        /** Assert playback was stopped and the player released (MediaPlayer::stop()). */
        FakeBridge::macro('assertStopped', function () {
            return $this->assertCalled('MediaPlayer.Stop');
        });

        /**
         * Assert a seek happened — anywhere, or to exactly $to seconds when
         * given (MediaPlayer::seek()).
         */
        FakeBridge::macro('assertSeeked', function (?float $to = null) {
            if ($to === null) {
                return $this->assertCalled('MediaPlayer.Seek');
            }

            $positions = array_map(
                fn (array $call) => (float) ($call['params']['seconds'] ?? 0.0),
                $this->callsTo('MediaPlayer.Seek')
            );

            Assert::assertContains(
                $to,
                $positions,
                "Expected a seek to [{$to}]s. Seeked to: "
                    .($positions === []
                        ? '(nothing)'
                        : implode('s, ', array_map(fn (float $p) => rtrim(rtrim(sprintf('%.4f', $p), '0'), '.'), $positions)).'s')
            );

            return $this;
        });

        /** Assert nothing was played (no MediaPlayer::play() call). */
        FakeBridge::macro('assertNothingPlayed', function () {
            return $this->assertNotCalled('MediaPlayer.Play');
        });
    }
}
