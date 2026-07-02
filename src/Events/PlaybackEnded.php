<?php

namespace NativePHP\MediaPlayer\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class PlaybackEnded
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $source = '',
    ) {}
}
