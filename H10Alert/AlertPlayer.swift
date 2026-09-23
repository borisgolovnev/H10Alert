//
//  AlertPlayer.swift
//  H10Alert
//
//  Created by Boris Golovnev on 15/06/2026.
//

import AVFoundation

final class AlertPlayer {
    private var soundPlayer: AVAudioPlayer?
    private var keepAliveActive = false
    private var soundUrl:URL!

    init(soundName:String) {
        soundUrl = Bundle.main.url(forResource: soundName, withExtension: "m4r")
        assert(soundUrl != nil)
        configureSession()
        registerObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Session

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Session setup failed: \(error)")
        }
    }

    // MARK: - Observers

    private func registerObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMediaReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            print("Interruption began")

        case .ended:
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            print("Interruption ended, shouldResume: \(opts.contains(.shouldResume))")
            reactivateAndResume()

        @unknown default:
            break
        }
    }

    @objc private func handleMediaReset(_ note: Notification) {
        print("Media services reset — rebuilding audio")
        soundPlayer = nil
        configureSession()
    }

    private func reactivateAndResume() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Re-activate failed: \(error)"); return
        }
    }

    // MARK: - Playback

    func startPlayback() {
        do {
            soundPlayer = try AVAudioPlayer(contentsOf: soundUrl)
            soundPlayer?.numberOfLoops = -1
            soundPlayer?.prepareToPlay()
            soundPlayer?.play()
        } catch {
            print("Playback failed: \(error)")
        }
    }

    func stopPlayback() {
        soundPlayer?.stop()
        soundPlayer = nil
    }
}
