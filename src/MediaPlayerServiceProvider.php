<?php

namespace NativePHP\MediaPlayer;

use Illuminate\Support\ServiceProvider;
use Native\Mobile\Testing\FakeBridge;
use NativePHP\MediaPlayer\Testing\MediaPlayerMacros;

class MediaPlayerServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(MediaPlayer::class, function () {
            return new MediaPlayer;
        });

        // Test sugar (assertPlayed() etc.) — only under a test runner, and
        // only on a core whose FakeBridge is macroable (the method_exists
        // guard keeps older v4 and v3 cores fatal-free).
        if ($this->app->runningUnitTests()
            && class_exists(FakeBridge::class)
            && method_exists(FakeBridge::class, 'macro')) {
            MediaPlayerMacros::register();
        }
    }
}
