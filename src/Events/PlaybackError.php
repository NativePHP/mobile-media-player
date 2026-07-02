<?php

namespace NativePHP\MediaPlayer\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class PlaybackError
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $source = '',
        public string $message = '',
    ) {}
}
