<?php

namespace NativePHP\MediaPlayer\Elements;

use Native\Mobile\Edge\CallbackRegistry;
use Native\Mobile\Edge\Element;

/**
 * AnimatedImage — an animated GIF / APNG / animated WebP surface.
 *
 * Neither platform's stock image renderer animates these formats: SwiftUI's
 * `AsyncImage` and Coil without its GIF decoder both stop at the first frame.
 * The obvious workaround — pointing `video_player` at an MP4 — does not
 * survive a list, because playback surfaces are a scarce resource: iOS shares
 * a single AVPlayer (a second source tears the first one down), and Android
 * runs out of hardware decoders after a handful. Animated images have no such
 * ceiling: they decode on the CPU into ordinary bitmaps, so a feed can show
 * dozens.
 *
 * Use `video_player` for video with audio and transport controls; use this for
 * decorative looping imagery.
 */
class AnimatedImage extends Element
{
    protected string $type = 'animated_image';

    /** @var array<string, mixed> */
    protected array $imageProps = [];

    public static function make(string $src = ''): static
    {
        $el = new static;
        if ($src !== '') {
            $el->imageProps['src'] = $src;
        }

        return $el;
    }

    public function applyAttributes(array $attrs): void
    {
        if (isset($attrs['src'])) {
            $this->src($attrs['src']);
        }
        if (isset($attrs['fit'])) {
            $this->fit((int) $attrs['fit']);
        }
        if (isset($attrs['alt'])) {
            $this->alt((string) $attrs['alt']);
        }
        if (isset($attrs['autoplay'])) {
            $this->autoplay(filter_var($attrs['autoplay'], FILTER_VALIDATE_BOOLEAN));
        }
        if (isset($attrs['loop'])) {
            $this->loop(filter_var($attrs['loop'], FILTER_VALIDATE_BOOLEAN));
        }
    }

    public function src(string $src): static
    {
        $this->imageProps['src'] = $src;

        return $this;
    }

    /** Matches `image`: 0/1 fit inside the bounds, 2/3 fill and crop. */
    public function fit(int $fit): static
    {
        $this->imageProps['fit'] = $fit;

        return $this;
    }

    public function alt(string $alt): static
    {
        $this->imageProps['alt'] = $alt;

        return $this;
    }

    public function autoplay(bool $value = true): static
    {
        $this->imageProps['autoplay'] = $value;

        return $this;
    }

    public function loop(bool $value = true): static
    {
        $this->imageProps['loop'] = $value;

        return $this;
    }

    protected function defaults(): array
    {
        return [
            'fit' => 1,
            'autoplay' => true,
            'loop' => true,
        ];
    }

    protected function resolveProps(CallbackRegistry $registry): array
    {
        return $this->imageProps;
    }
}
