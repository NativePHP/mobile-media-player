<?php

use NativePHP\MediaPlayer\MediaPlayer;

beforeEach(function () {
    $this->pluginPath = dirname(__DIR__);
    $this->manifestPath = $this->pluginPath.'/nativephp.json';
});

describe('Plugin Manifest', function () {
    it('has a valid nativephp.json file', function () {
        expect(file_exists($this->manifestPath))->toBeTrue();

        $content = file_get_contents($this->manifestPath);
        $manifest = json_decode($content, true);

        expect(json_last_error())->toBe(JSON_ERROR_NONE);
    });

    it('has required fields', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect($manifest)->toHaveKeys(['namespace', 'bridge_functions', 'components']);
        expect($manifest['namespace'])->toBe('MediaPlayer');
    });

    it('has valid bridge functions', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect($manifest['bridge_functions'])->toBeArray();
        expect($manifest['bridge_functions'])->toHaveCount(8);

        foreach ($manifest['bridge_functions'] as $function) {
            expect($function)->toHaveKeys(['name', 'android', 'ios']);
        }
    });

    it('registers all expected bridge function names', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);
        $names = array_column($manifest['bridge_functions'], 'name');

        expect($names)->toContain('MediaPlayer.Play');
        expect($names)->toContain('MediaPlayer.Pause');
        expect($names)->toContain('MediaPlayer.Resume');
        expect($names)->toContain('MediaPlayer.Stop');
        expect($names)->toContain('MediaPlayer.Seek');
        expect($names)->toContain('MediaPlayer.SetVolume');
        expect($names)->toContain('MediaPlayer.GetStatus');
        expect($names)->toContain('MediaPlayer.Present');
    });

    it('registers the video_player component', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect($manifest['components'])->toHaveCount(1);

        $component = $manifest['components'][0];

        expect($component['type'])->toBe('video_player');
        expect($component['element'])->toBe('NativePHP\\MediaPlayer\\Elements\\VideoPlayer');
        expect($component['blade'])->toBe('NativePHP\\MediaPlayer\\Components\\VideoPlayer');
        expect($component)->toHaveKeys(['android_renderer', 'ios_renderer', 'self_closing']);
        expect($component['self_closing'])->toBeTrue();
    });

    it('declares the fullscreen player activity', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);
        $names = array_column($manifest['android']['activities'], 'name');

        expect($names)->toContain('com.nativephp.plugins.media_player.FullscreenPlayerActivity');
    });

    it('registers events', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect($manifest['events'])->toContain('NativePHP\\MediaPlayer\\Events\\PlaybackEnded');
        expect($manifest['events'])->toContain('NativePHP\\MediaPlayer\\Events\\PlaybackError');
    });
});

describe('Native Code', function () {
    it('has Android Kotlin files', function () {
        expect(file_exists($this->pluginPath.'/resources/android/MediaPlayerManager.kt'))->toBeTrue();
        expect(file_exists($this->pluginPath.'/resources/android/MediaPlayerFunctions.kt'))->toBeTrue();
        expect(file_exists($this->pluginPath.'/resources/android/FullscreenPlayerActivity.kt'))->toBeTrue();
        expect(file_exists($this->pluginPath.'/resources/android/ui/VideoPlayerRenderer.kt'))->toBeTrue();
    });

    it('has iOS Swift files', function () {
        expect(file_exists($this->pluginPath.'/resources/ios/MediaPlayerManager.swift'))->toBeTrue();
        expect(file_exists($this->pluginPath.'/resources/ios/MediaPlayerFunctions.swift'))->toBeTrue();
        expect(file_exists($this->pluginPath.'/resources/ios/MediaPlayerVideoRenderer.swift'))->toBeTrue();
    });

    it('declares Kotlin packages matching the manifest', function () {
        $functions = file_get_contents($this->pluginPath.'/resources/android/MediaPlayerFunctions.kt');
        $renderer = file_get_contents($this->pluginPath.'/resources/android/ui/VideoPlayerRenderer.kt');

        expect($functions)->toContain('package com.nativephp.plugins.media_player');
        expect($renderer)->toContain('package com.nativephp.plugins.media_player.ui');
    });
});

describe('PHP Classes', function () {
    it('has service provider', function () {
        $file = $this->pluginPath.'/src/MediaPlayerServiceProvider.php';
        expect(file_exists($file))->toBeTrue();
    });

    it('has facade', function () {
        $file = $this->pluginPath.'/src/Facades/MediaPlayer.php';
        expect(file_exists($file))->toBeTrue();
    });

    it('has main implementation class', function () {
        $file = $this->pluginPath.'/src/MediaPlayer.php';
        expect(file_exists($file))->toBeTrue();
    });

    it('has VideoPlayer element', function () {
        $file = $this->pluginPath.'/src/Elements/VideoPlayer.php';
        expect(file_exists($file))->toBeTrue();
    });

    it('has VideoPlayer blade component', function () {
        $file = $this->pluginPath.'/src/Components/VideoPlayer.php';
        expect(file_exists($file))->toBeTrue();
    });

    it('has PlaybackEnded event', function () {
        $file = $this->pluginPath.'/src/Events/PlaybackEnded.php';
        expect(file_exists($file))->toBeTrue();
    });

    it('has PlaybackError event', function () {
        $file = $this->pluginPath.'/src/Events/PlaybackError.php';
        expect(file_exists($file))->toBeTrue();
    });
});

describe('Composer Configuration', function () {
    it('has valid composer.json', function () {
        $composerPath = $this->pluginPath.'/composer.json';
        expect(file_exists($composerPath))->toBeTrue();

        $content = file_get_contents($composerPath);
        $composer = json_decode($content, true);

        expect(json_last_error())->toBe(JSON_ERROR_NONE);
        expect($composer['type'])->toBe('nativephp-plugin');
        expect($composer['name'])->toBe('nativephp/mobile-media-player');
        expect($composer['extra']['laravel']['providers'])
            ->toContain('NativePHP\\MediaPlayer\\MediaPlayerServiceProvider');
    });
});

describe('MediaPlayer', function () {
    it('returns an idle status by default off-device', function () {
        require_once $this->pluginPath.'/src/MediaPlayer.php';

        $status = (new MediaPlayer)->getStatus();

        expect($status)->toBe([
            'state' => 'idle',
            'position' => 0.0,
            'duration' => 0.0,
            'source' => null,
        ]);
    });

    it('reports failure when the bridge is unavailable', function () {
        require_once $this->pluginPath.'/src/MediaPlayer.php';

        $player = new MediaPlayer;

        expect($player->play('https://example.com/video.mp4'))->toBeFalse();
        expect($player->present('https://example.com/video.mp4'))->toBeFalse();
    });
});
