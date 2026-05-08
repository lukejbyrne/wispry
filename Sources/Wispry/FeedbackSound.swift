import AppKit
import Foundation

final class FeedbackSound {
    static let shared = FeedbackSound()

    private let sampleRate = 44_100
    private var activeSounds: [NSSound] = []

    private struct ToneSegment {
        let startFrequency: Double
        let endFrequency: Double
        let duration: Double
        let amplitude: Double
        let noise: Double
    }

    private init() {}

    func playStart() {
        play([
            ToneSegment(startFrequency: 520, endFrequency: 720, duration: 0.055, amplitude: 0.46, noise: 0.018),
            ToneSegment(startFrequency: 760, endFrequency: 980, duration: 0.075, amplitude: 0.34, noise: 0.012)
        ])
    }

    func playStop() {
        play([
            ToneSegment(startFrequency: 860, endFrequency: 680, duration: 0.05, amplitude: 0.36, noise: 0.012),
            ToneSegment(startFrequency: 620, endFrequency: 420, duration: 0.085, amplitude: 0.28, noise: 0.016)
        ])
    }

    func playCancel() {
        play([
            ToneSegment(startFrequency: 360, endFrequency: 240, duration: 0.09, amplitude: 0.22, noise: 0.014)
        ])
    }

    private func play(_ segments: [ToneSegment]) {
        guard let sound = NSSound(data: wavData(for: segments)) else {
            NSSound(named: "Tink")?.play()
            return
        }

        sound.volume = 0.34
        activeSounds.append(sound)
        sound.play()

        let cleanupDelay = segments.reduce(0.25) { $0 + $1.duration }
        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay) { [weak self, weak sound] in
            guard let self, let sound else { return }
            activeSounds.removeAll { $0 === sound }
        }
    }

    private func wavData(for segments: [ToneSegment]) -> Data {
        let samples = samples(for: segments)
        let dataSize = samples.count * MemoryLayout<Int16>.size
        var data = Data()

        appendASCII("RIFF", to: &data)
        appendUInt32(UInt32(36 + dataSize), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(sampleRate * 2), to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        appendASCII("data", to: &data)
        appendUInt32(UInt32(dataSize), to: &data)

        for sample in samples {
            var littleEndian = sample.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }

        return data
    }

    private func samples(for segments: [ToneSegment]) -> [Int16] {
        var samples: [Int16] = []
        var phase = 0.0
        var seed: UInt64 = 0x6d2b79f5

        for segment in segments {
            let count = max(1, Int(segment.duration * Double(sampleRate)))
            for index in 0..<count {
                let progress = Double(index) / Double(max(1, count - 1))
                let frequency = segment.startFrequency + (segment.endFrequency - segment.startFrequency) * progress
                phase += 2.0 * .pi * frequency / Double(sampleRate)

                seed = seed &* 6364136223846793005 &+ 1
                let noiseValue = (Double((seed >> 33) & 0xffff) / 32767.5) - 1.0
                let envelope = sin(.pi * progress)
                let raw = (sin(phase) * segment.amplitude + noiseValue * segment.noise) * envelope
                let clamped = min(1.0, max(-1.0, raw))
                samples.append(Int16(clamped * Double(Int16.max)))
            }

            samples.append(contentsOf: Array(repeating: 0, count: Int(0.012 * Double(sampleRate))))
        }

        return samples
    }

    private func appendASCII(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
