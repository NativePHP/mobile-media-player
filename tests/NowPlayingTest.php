<?php

/**
 * Now Playing metadata: the title / artist / artwork passed to play() are what
 * populate the lock screen, Control Center and Dynamic Island.
 *
 * Skipped on cores whose FakeBridge predates macro support.
 */

use Native\Mobile\Testing\FakeBridge;
use Native\Mobile\Testing\Native;
use NativePHP\MediaPlayer\Events\RemoteCommand;
use NativePHP\MediaPlayer\MediaPlayer;
use Tests\TestCase;

uses(TestCase::class);

beforeEach(function () {
    if (! method_exists(FakeBridge::class, 'macro')) {
        $this->markTestSkipped('This core\'s FakeBridge does not support macros.');
    }

    $this->bridge = Native::fakeBridge();
});

describe('play() metadata', function () {
    it('forwards now-playing metadata to the bridge', function () {
        (new MediaPlayer)->play('https://example.com/live.m3u8', [
            'title' => 'The Platform',
            'artist' => 'Live stream',
            'artwork' => 'https://example.com/logo.png',
        ]);

        $params = $this->bridge->callsTo('MediaPlayer.Play')[0]['params'];

        expect($params)
            ->toHaveKey('title', 'The Platform')
            ->toHaveKey('artist', 'Live stream')
            ->toHaveKey('artwork', 'https://example.com/logo.png');
    });

    it('omits metadata keys that were not provided', function () {
        (new MediaPlayer)->play('https://example.com/live.m3u8');

        $params = $this->bridge->callsTo('MediaPlayer.Play')[0]['params'];

        expect($params)
            ->not->toHaveKey('title')
            ->not->toHaveKey('artist')
            ->not->toHaveKey('artwork')
            ->toHaveKey('source', 'https://example.com/live.m3u8');
    });

    it('still sends loop and volume alongside metadata', function () {
        (new MediaPlayer)->play('https://example.com/live.m3u8', [
            'volume' => 0.5,
            'loop' => true,
            'title' => 'The Platform',
        ]);

        $params = $this->bridge->callsTo('MediaPlayer.Play')[0]['params'];

        expect($params)
            ->toHaveKey('loop', true)
            ->toHaveKey('volume', 0.5)
            ->toHaveKey('title', 'The Platform');
    });

    it('keeps a false loop, which array_filter must not strip', function () {
        (new MediaPlayer)->play('https://example.com/live.m3u8', ['loop' => false]);

        $params = $this->bridge->callsTo('MediaPlayer.Play')[0]['params'];

        expect($params)->toHaveKey('loop', false);
    });
});

describe('RemoteCommand', function () {
    it('carries the command and source', function () {
        $event = new RemoteCommand('stop', 'https://example.com/live.m3u8');

        expect($event->command)->toBe('stop')
            ->and($event->source)->toBe('https://example.com/live.m3u8');
    });

    it('defaults to empty strings', function () {
        $event = new RemoteCommand;

        expect($event->command)->toBe('')
            ->and($event->source)->toBe('');
    });
});
