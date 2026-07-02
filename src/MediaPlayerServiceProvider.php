<?php

namespace NativePHP\MediaPlayer;

use Illuminate\Support\ServiceProvider;

class MediaPlayerServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(MediaPlayer::class, function () {
            return new MediaPlayer;
        });
    }
}
