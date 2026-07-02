<?php

namespace NativePHP\MediaPlayer\Facades;

use Illuminate\Support\Facades\Facade;

/**
 * @method static bool play(string $source, array $options = [])
 * @method static void pause()
 * @method static void resume()
 * @method static void stop()
 * @method static void seek(float $seconds)
 * @method static void setVolume(float $volume)
 * @method static array getStatus()
 * @method static bool present(string $source)
 *
 * @see \NativePHP\MediaPlayer\MediaPlayer
 */
class MediaPlayer extends Facade
{
    protected static function getFacadeAccessor(): string
    {
        return \NativePHP\MediaPlayer\MediaPlayer::class;
    }
}
