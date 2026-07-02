import AVFoundation
import AVKit
import Foundation
import UIKit

// MARK: - MediaPlayer Function Namespace

/// Functions related to media playback operations
/// Namespace: "MediaPlayer.*"
enum MediaPlayerFunctions {

    // MARK: - MediaPlayer.Play

    /// Start or replace playback of a file path or URL on the shared player
    /// Parameters:
    ///   - source: string - File path or URL to play
    ///   - loop: (optional) boolean - Restart playback when the item ends (default: false)
    ///   - volume: (optional) float - Playback volume 0.0 - 1.0 (default: 1.0)
    /// Returns:
    ///   - success: boolean - True if playback started
    /// Events:
    ///   - Fires "NativePHP\MediaPlayer\Events\PlaybackEnded" when playback finishes
    ///   - Fires "NativePHP\MediaPlayer\Events\PlaybackError" on failure
    class Play: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let source = parameters["source"] as? String, !source.isEmpty else {
                throw BridgeError.invalidParameters("source is required")
            }

            let loop = parameters["loop"] as? Bool ?? false
            let volume = (parameters["volume"] as? NSNumber)?.floatValue ?? 1.0

            print("🎬 Starting media playback: \(source)")

            var success = false
            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.main.async {
                success = MediaPlayerManager.shared.play(source: source, loop: loop, volume: volume)
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 2)

            return ["success": success]
        }
    }

    // MARK: - MediaPlayer.Pause

    /// Pause the current playback
    class Pause: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            print("⏸️ Pausing media playback")

            DispatchQueue.main.async {
                MediaPlayerManager.shared.pause()
            }

            return [:]
        }
    }

    // MARK: - MediaPlayer.Resume

    /// Resume paused playback
    class Resume: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            print("▶️ Resuming media playback")

            DispatchQueue.main.async {
                MediaPlayerManager.shared.resume()
            }

            return [:]
        }
    }

    // MARK: - MediaPlayer.Stop

    /// Stop playback and release the shared player
    class Stop: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            print("⏹️ Stopping media playback")

            DispatchQueue.main.async {
                MediaPlayerManager.shared.stop()
            }

            return [:]
        }
    }

    // MARK: - MediaPlayer.Seek

    /// Seek to a position in seconds
    /// Parameters:
    ///   - seconds: float - Position to seek to
    class Seek: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let seconds = (parameters["seconds"] as? NSNumber)?.doubleValue ?? 0

            DispatchQueue.main.async {
                MediaPlayerManager.shared.seek(to: seconds)
            }

            return [:]
        }
    }

    // MARK: - MediaPlayer.SetVolume

    /// Set playback volume
    /// Parameters:
    ///   - volume: float - Volume 0.0 - 1.0
    class SetVolume: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let volume = (parameters["volume"] as? NSNumber)?.floatValue ?? 1.0

            DispatchQueue.main.async {
                MediaPlayerManager.shared.setVolume(volume)
            }

            return [:]
        }
    }

    // MARK: - MediaPlayer.GetStatus

    /// Get current playback status
    /// Returns:
    ///   - state: string - "idle", "playing", "paused", "ended" or "error"
    ///   - position: float - Current position in seconds
    ///   - duration: float - Item duration in seconds
    ///   - source: string - Currently loaded source ("" when idle)
    class GetStatus: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            var status: [String: Any] = [
                "state": "idle",
                "position": 0.0,
                "duration": 0.0,
                "source": "",
            ]

            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.main.async {
                status = MediaPlayerManager.shared.getStatus()
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 2)

            return status
        }
    }

    // MARK: - MediaPlayer.Present

    /// Present a full-screen AVPlayerViewController from the root view
    /// controller. The user dismisses it natively (same presentation
    /// boilerplate as the browser / camera plugins).
    /// Parameters:
    ///   - source: string - File path or URL to play
    /// Returns:
    ///   - success: boolean - True if the player was presented
    class Present: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let source = parameters["source"] as? String, !source.isEmpty else {
                throw BridgeError.invalidParameters("source is required")
            }

            guard let url = MediaPlayerManager.resolveURL(source) else {
                throw BridgeError.invalidParameters("Could not resolve source URL")
            }

            print("🎬 Presenting full-screen player: \(source)")

            var success = false
            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.main.async {
                // Don't fight the shared player for audio focus.
                MediaPlayerManager.shared.stop()
                MediaPlayerManager.shared.configureAudioSession()

                guard let windowScene = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene })
                        .first(where: { $0.activationState == .foregroundActive })
                        ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                      let rootVC = windowScene.windows
                        .first(where: { $0.isKeyWindow })?
                        .rootViewController else {
                    print("❌ Failed to get root view controller")
                    semaphore.signal()
                    return
                }

                // Find the topmost view controller
                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }

                let playerVC = AVPlayerViewController()
                playerVC.player = AVPlayer(url: url)
                playerVC.modalPresentationStyle = .fullScreen

                topVC.present(playerVC, animated: true) {
                    playerVC.player?.play()
                    success = true
                    semaphore.signal()
                }
            }

            _ = semaphore.wait(timeout: .now() + 2)

            return ["success": success]
        }
    }
}
