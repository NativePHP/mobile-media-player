<?php

/**
 * The events in nativephp.json are the ones MediaPlayerManager sends back
 * from native code, and they reach PHP through POST /_native/api/events.
 * Since nativephp/mobile 4.6.1 / 3.3.11 that endpoint refuses any class
 * without the DispatchableFromNative marker, and the event never fires.
 */

use Native\Mobile\Events\Contracts\DispatchableFromNative;

$sent = array_values(array_filter(
    json_decode(file_get_contents(dirname(__DIR__).'/nativephp.json'), true)['events'] ?? [],
    fn (string $class) => str_starts_with($class, 'NativePHP\\MediaPlayer\\'),
));

it('is let through /_native/api/events', function (string $class) {
    expect(class_exists($class))->toBeTrue()
        ->and(is_subclass_of($class, DispatchableFromNative::class))->toBeTrue();
})->with($sent);
