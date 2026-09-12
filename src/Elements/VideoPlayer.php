<?php

namespace NativePHP\MediaPlayer\Elements;

use Native\Mobile\Edge\CallbackRegistry;
use Native\Mobile\Edge\Element;

/**
 * VideoPlayer — inline video surface. Renders as a SwiftUI `VideoPlayer`
 * (AVKit) on iOS and a `VideoView` inside a Compose `AndroidView` on Android.
 *
 * With `controls=false` a bare video surface is rendered (no transport
 * chrome) so developers can overlay their own Element UI and drive playback
 * through the `MediaPlayer` facade. Sizing follows the element's layout
 * props (width / height / aspect) like `Image` does.
 */
class VideoPlayer extends Element
{
    protected string $type = 'video_player';

    /** @var array<string, mixed> */
    protected array $videoProps = [];

    public static function make(string $src = ''): static
    {
        $el = new static;
        if ($src !== '') {
            $el->videoProps['src'] = $src;
        }

        return $el;
    }

    public function applyAttributes(array $attrs): void
    {
        if (isset($attrs['src'])) {
            $this->src($attrs['src']);
        }
        if (isset($attrs['controls'])) {
            $this->controls(filter_var($attrs['controls'], FILTER_VALIDATE_BOOLEAN));
        }
        if (isset($attrs['autoplay'])) {
            $this->autoplay(filter_var($attrs['autoplay'], FILTER_VALIDATE_BOOLEAN));
        }
        if (isset($attrs['loop'])) {
            $this->loop(filter_var($attrs['loop'], FILTER_VALIDATE_BOOLEAN));
        }
        if (isset($attrs['muted'])) {
            $this->muted(filter_var($attrs['muted'], FILTER_VALIDATE_BOOLEAN));
        }
        // Same contract as Image: 1 contain (default), 2 cover, 3 fill.
        // `object-cover` / `object-contain` / `object-fill` classes land
        // here too — the collector folds Tailwind-derived attrs in.
        if (isset($attrs['fit'])) {
            $this->fit((int) $attrs['fit']);
        }
    }

    public function src(string $src): static
    {
        $this->videoProps['src'] = $src;

        return $this;
    }

    public function controls(bool $value = true): static
    {
        $this->videoProps['controls'] = $value;

        return $this;
    }

    public function autoplay(bool $value = true): static
    {
        $this->videoProps['autoplay'] = $value;

        return $this;
    }

    public function loop(bool $value = true): static
    {
        $this->videoProps['loop'] = $value;

        return $this;
    }

    public function muted(bool $value = true): static
    {
        $this->videoProps['muted'] = $value;

        return $this;
    }

    /**
     * How the frame is fitted into the surface: 1 contain (letterbox,
     * default), 2 cover (fill and crop — the reel / feed look), 3 fill
     * (stretch). Mirrors Image::fit() and the `object-*` classes.
     */
    public function fit(int $mode): static
    {
        $this->videoProps['fit'] = $mode;

        return $this;
    }

    protected function defaults(): array
    {
        return [
            'controls' => true,
            'autoplay' => false,
            'loop' => false,
            'muted' => false,
        ];
    }

    protected function resolveProps(CallbackRegistry $registry): array
    {
        return $this->videoProps;
    }
}
