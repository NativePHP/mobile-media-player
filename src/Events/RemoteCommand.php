<?php

namespace NativePHP\MediaPlayer\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Fired when the user drives playback from outside the app — the lock screen,
 * Control Center, the Dynamic Island, headphone controls or CarPlay.
 *
 * The native side has already applied the command to the shared player by the
 * time this reaches PHP, so handlers exist to reconcile in-app UI rather than
 * to perform the action.
 *
 * `$command` is one of `play`, `pause` or `stop`. Note that live streams never
 * report `pause`: the system renders a stop button for live content, so a live
 * halt arrives as `stop`.
 */
class RemoteCommand
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $command = '',
        public string $source = '',
    ) {}
}
