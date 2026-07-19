<?php

/**
 * The media player test vocabulary this plugin registers on the FakeBridge
 * (withPlaybackStatus / assertPlayed / assertPaused / assertStopped /
 * assertSeeked / assertNothingPlayed) — the sugar app developers use instead
 * of raw bridge method strings.
 *
 * Skipped on cores whose FakeBridge predates macro support.
 */

use Native\Mobile\Testing\FakeBridge;
use Native\Mobile\Testing\Native;
use NativePHP\MediaPlayer\MediaPlayer;
use PHPUnit\Framework\AssertionFailedError;
use Tests\TestCase;

uses(TestCase::class);

beforeEach(function () {
    if (! method_exists(FakeBridge::class, 'macro')) {
        $this->markTestSkipped('This core\'s FakeBridge does not support macros.');
    }

    $this->bridge = Native::fakeBridge();
});

describe('withPlaybackStatus()', function () {
    it('scripts the status getStatus() reports', function () {
        $this->bridge->withPlaybackStatus('playing', position: 12.0, duration: 180.0, source: 'song.mp3');

        expect((new MediaPlayer)->getStatus())->toBe([
            'state' => 'playing',
            'position' => 12.0,
            'duration' => 180.0,
            'source' => 'song.mp3',
        ]);
    });

    it('defaults to a playing player at the start of the timeline', function () {
        $this->bridge->withPlaybackStatus();

        expect((new MediaPlayer)->getStatus())->toBe([
            'state' => 'playing',
            'position' => 0.0,
            'duration' => 0.0,
            'source' => null,
        ]);
    });
});

describe('assertPlayed()', function () {
    it('passes when any source was played', function () {
        (new MediaPlayer)->play('anything.mp3');

        $this->bridge->assertPlayed();
    });

    it('matches the exact played source', function () {
        (new MediaPlayer)->play('first.mp3');
        (new MediaPlayer)->play('https://example.com/stream.mp3');

        $this->bridge->assertPlayed('https://example.com/stream.mp3');
    });

    it('fails when nothing was played', function () {
        expect(fn () => $this->bridge->assertPlayed())
            ->toThrow(AssertionFailedError::class);
    });

    it('fails when a different source was played, naming what was', function () {
        (new MediaPlayer)->play('actual.mp3');

        expect(fn () => $this->bridge->assertPlayed('expected.mp3'))
            ->toThrow(AssertionFailedError::class, 'actual.mp3');
    });
});

describe('assertPaused()', function () {
    it('passes after a pause', function () {
        (new MediaPlayer)->pause();

        $this->bridge->assertPaused();
    });

    it('fails when nothing was paused', function () {
        expect(fn () => $this->bridge->assertPaused())
            ->toThrow(AssertionFailedError::class);
    });
});

describe('assertStopped()', function () {
    it('passes after a stop', function () {
        (new MediaPlayer)->stop();

        $this->bridge->assertStopped();
    });

    it('fails when nothing was stopped', function () {
        expect(fn () => $this->bridge->assertStopped())
            ->toThrow(AssertionFailedError::class);
    });
});

describe('assertSeeked()', function () {
    it('passes when a seek happened anywhere', function () {
        (new MediaPlayer)->seek(30.0);

        $this->bridge->assertSeeked();
    });

    it('matches the exact seek position', function () {
        (new MediaPlayer)->seek(10.0);
        (new MediaPlayer)->seek(42.5);

        $this->bridge->assertSeeked(42.5);
    });

    it('fails when no seek happened', function () {
        expect(fn () => $this->bridge->assertSeeked())
            ->toThrow(AssertionFailedError::class);
    });

    it('fails when a different position was sought, naming what was', function () {
        (new MediaPlayer)->seek(10.0);

        expect(fn () => $this->bridge->assertSeeked(99.0))
            ->toThrow(AssertionFailedError::class, '10');
    });
});

describe('assertNothingPlayed()', function () {
    it('passes when no play happened', function () {
        (new MediaPlayer)->getStatus();

        $this->bridge->assertNothingPlayed();
    });

    it('fails after a play', function () {
        (new MediaPlayer)->play('oops.mp3');

        expect(fn () => $this->bridge->assertNothingPlayed())
            ->toThrow(AssertionFailedError::class);
    });
});
