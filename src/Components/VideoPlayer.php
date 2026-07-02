<?php

namespace NativePHP\MediaPlayer\Components;

use Native\Mobile\Edge\Components\Native\NativeBladeComponent;

class VideoPlayer extends NativeBladeComponent
{
    protected bool $isSelfClosing = true;

    protected function elementType(): string
    {
        return 'video_player';
    }
}
