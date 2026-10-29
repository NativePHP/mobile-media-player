<?php

namespace NativePHP\MediaPlayer;

use Illuminate\Support\ServiceProvider;
use Native\Mobile\Edge\Web\Renderer\HtmlRendererRegistry;
use Native\Mobile\Edge\Web\Renderer\WebRenderer;
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

    public function boot(): void
    {
        $this->registerWebRenderers();
    }

    /**
     * The web target has no renderer for a plugin's element types unless the
     * plugin supplies one, and an unknown leaf renders as nothing — so both
     * elements would silently vanish in the browser. HTML has native
     * equivalents for both, so author code renders on every target.
     */
    protected function registerWebRenderers(): void
    {
        if (! class_exists(HtmlRendererRegistry::class)) {
            return;
        }

        HtmlRendererRegistry::register('video_player', function (array $node): string {
            $props = $node['props'] ?? [];
            $src = (string) ($props['src'] ?? '');

            if ($src === '') {
                return '';
            }

            // `playsinline` and `muted` are both required for autoplay to
            // survive mobile Safari's blocking policy.
            $attrs = ['playsinline'];
            foreach (['controls', 'autoplay', 'loop', 'muted'] as $flag) {
                if (($props[$flag] ?? false) === true) {
                    $attrs[] = $flag;
                }
            }

            return '<video'.WebRenderer::idAttr($node)
                .' class="'.WebRenderer::cls($node, 'object-cover').'"'
                .' src="'.e($src).'" '.implode(' ', $attrs).'></video>';
        });

        HtmlRendererRegistry::register('animated_image', function (array $node): string {
            $props = $node['props'] ?? [];
            $src = (string) ($props['src'] ?? '');

            if ($src === '') {
                return '';
            }

            // Browsers animate GIF / APNG / animated WebP in a plain <img>,
            // and honour the file's own loop count — so `autoplay` and `loop`
            // have no web equivalent to apply.
            $alt = (string) ($props['alt'] ?? '');
            $fit = (int) ($props['fit'] ?? 1);
            $object = match ($fit) {
                0 => 'object-none',
                2 => 'object-cover',
                3 => 'object-fill',
                default => 'object-contain',
            };

            return '<img'.WebRenderer::idAttr($node)
                .' class="'.WebRenderer::cls($node, $object.' max-w-full').'"'
                .' src="'.e($src).'" alt="'.e($alt).'">';
        });
    }
}
