<?php

namespace NativePHP\MediaPlayer\Components;

use Native\Mobile\Edge\Components\Native\NativeBladeComponent;

class AnimatedImage extends NativeBladeComponent
{
    protected bool $isSelfClosing = true;

    protected function elementType(): string
    {
        return 'animated_image';
    }
}
