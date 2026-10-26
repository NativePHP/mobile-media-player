<?php

namespace NativePHP\MediaPlayer\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;
use Native\Mobile\Events\Contracts\DispatchableFromNative;

class PlaybackEnded implements DispatchableFromNative
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $source = '',
    ) {}
}
