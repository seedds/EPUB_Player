//
//  AudioFixture.swift
//  EPUB PlayerTests
//

import AVFoundation
import Foundation

/// Writes tiny, genuinely-playable audio files for playback tests. Using a real
/// file (instead of a nonexistent path) lets the controller's AVPlayerItem
/// actually reach `.readyToPlay`, so tests exercise the true playing state
/// alongside the item-failure observation added for finding #8.
enum AudioFixture {
    /// Creates a short silent CAF/LPCM file on disk and returns its URL. LPCM in
    /// a CAF container needs no codec and loads reliably in the simulator.
    static func makeSilentFile(seconds: Double = 1.0) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("caf")

        let sampleRate = 44_100.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // frameCapacity zero-fills the channel data, so the buffer is silence.
        try file.write(from: buffer)

        return url
    }
}
