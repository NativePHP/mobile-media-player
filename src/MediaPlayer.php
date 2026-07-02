<?php

namespace NativePHP\MediaPlayer;

class MediaPlayer
{
    /**
     * Start (or replace) playback of a file path or URL on the shared player.
     *
     * @param  array{loop?: bool, volume?: float}  $options
     */
    public function play(string $source, array $options = []): bool
    {
        if (function_exists('nativephp_call')) {
            $result = nativephp_call('MediaPlayer.Play', json_encode([
                'source' => $source,
                'loop' => (bool) ($options['loop'] ?? false),
                'volume' => (float) ($options['volume'] ?? 1.0),
            ]));

            if ($result) {
                $decoded = json_decode($result, true);

                return (bool) ($decoded['success'] ?? false);
            }
        }

        return false;
    }

    /**
     * Pause the current playback
     */
    public function pause(): void
    {
        if (function_exists('nativephp_call')) {
            nativephp_call('MediaPlayer.Pause', json_encode([]));
        }
    }

    /**
     * Resume paused playback
     */
    public function resume(): void
    {
        if (function_exists('nativephp_call')) {
            nativephp_call('MediaPlayer.Resume', json_encode([]));
        }
    }

    /**
     * Stop playback and release the shared player
     */
    public function stop(): void
    {
        if (function_exists('nativephp_call')) {
            nativephp_call('MediaPlayer.Stop', json_encode([]));
        }
    }

    /**
     * Seek to a position in seconds
     */
    public function seek(float $seconds): void
    {
        if (function_exists('nativephp_call')) {
            nativephp_call('MediaPlayer.Seek', json_encode([
                'seconds' => $seconds,
            ]));
        }
    }

    /**
     * Set playback volume (0.0 - 1.0)
     */
    public function setVolume(float $volume): void
    {
        if (function_exists('nativephp_call')) {
            nativephp_call('MediaPlayer.SetVolume', json_encode([
                'volume' => max(0.0, min(1.0, $volume)),
            ]));
        }
    }

    /**
     * Get the current playback status
     *
     * @return array{state: string, position: float, duration: float, source: string|null}
     */
    public function getStatus(): array
    {
        $default = [
            'state' => 'idle',
            'position' => 0.0,
            'duration' => 0.0,
            'source' => null,
        ];

        if (function_exists('nativephp_call')) {
            $result = nativephp_call('MediaPlayer.GetStatus', json_encode([]));

            if ($result) {
                $decoded = json_decode($result, true);

                if (is_array($decoded)) {
                    return [
                        'state' => (string) ($decoded['state'] ?? 'idle'),
                        'position' => (float) ($decoded['position'] ?? 0.0),
                        'duration' => (float) ($decoded['duration'] ?? 0.0),
                        'source' => isset($decoded['source']) && $decoded['source'] !== ''
                            ? (string) $decoded['source']
                            : null,
                    ];
                }
            }
        }

        return $default;
    }

    /**
     * Present a full-screen system player (AVPlayerViewController on iOS,
     * a full-screen playback activity on Android). The user dismisses it natively.
     */
    public function present(string $source): bool
    {
        if (function_exists('nativephp_call')) {
            $result = nativephp_call('MediaPlayer.Present', json_encode([
                'source' => $source,
            ]));

            if ($result) {
                $decoded = json_decode($result, true);

                return (bool) ($decoded['success'] ?? false);
            }
        }

        return false;
    }
}
