<?php

namespace Tests;

use Native\Mobile\NativeServiceProvider;
use NativePHP\MediaPlayer\MediaPlayerServiceProvider;
use Orchestra\Testbench\TestCase as BaseTestCase;

/**
 * Bootstraps a minimal Laravel app (Testbench) with the NativePHP core
 * provider — which loads the nativephp_call() polyfill — plus this plugin's
 * provider. The macro tests drive the FakeBridge test vocabulary the plugin
 * registers (assertPlayed() etc.) without a device.
 */
abstract class TestCase extends BaseTestCase
{
    protected function getPackageProviders($app)
    {
        return [
            NativeServiceProvider::class,
            MediaPlayerServiceProvider::class,
        ];
    }

    protected function getEnvironmentSetUp($app)
    {
        $app['config']->set('nativephp.app_id', 'com.test.app');
        $app['config']->set('nativephp.version', '1.0.0');
        $app['config']->set('nativephp.version_code', 1);
        $app['config']->set('app.name', 'Test App');
    }
}
