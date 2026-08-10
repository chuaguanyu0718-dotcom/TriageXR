@preconcurrency import AVFAudio
import AVFoundation
import Foundation

@MainActor
final class IncidentAudioCoordinator: ObservableObject {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var players: [AVAudioPlayerNode] = []
    private var callTask: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        engine.attach(environment)
        environment.renderingAlgorithm = .HRTFHQ
        environment.distanceAttenuationParameters.referenceDistance = 0.7
        environment.distanceAttenuationParameters.maximumDistance = 24
        environment.distanceAttenuationParameters.rolloffFactor = 1.15
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        addLoop(kind: .wind, position: AVAudio3DPoint(x: 0, y: 1.8, z: -7), volume: 0.16)
        addLoop(kind: .traffic, position: AVAudio3DPoint(x: -7, y: 0.2, z: -12), volume: 0.2)
        addLoop(kind: .siren, position: AVAudio3DPoint(x: 8, y: 0.6, z: -18), volume: 0.16)
        addLoop(kind: .leak, position: AVAudio3DPoint(x: -1.65, y: -0.8, z: -3.75), volume: 0.28)
        addLoop(kind: .injuredVoice, position: AVAudio3DPoint(x: 1.55, y: -0.7, z: -2.2), volume: 0.24)

        do {
            engine.prepare()
            try engine.start()
            players.forEach { $0.play() }
            beginDirectionalCalls()
        } catch {
            stop()
        }
    }

    func stop() {
        callTask?.cancel()
        callTask = nil
        players.forEach { $0.stop() }
        engine.stop()
        players.removeAll()
        started = false
    }

    func updateListener(position: SIMD3<Float>, yawRadians: Float) {
        environment.listenerPosition = AVAudio3DPoint(
            x: position.x,
            y: position.y,
            z: position.z
        )
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: yawRadians * 180 / .pi,
            pitch: 0,
            roll: 0
        )
    }

    private func addLoop(kind: SoundKind, position: AVAudio3DPoint, volume: Float) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let buffer = makeBuffer(kind: kind, format: format, duration: kind.duration) else { return }
        let player = AVAudioPlayerNode()
        player.position = position
        player.volume = volume
        player.renderingAlgorithm = .HRTFHQ
        engine.attach(player)
        engine.connect(player, to: environment, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        players.append(player)
    }

    private func beginDirectionalCalls() {
        callTask?.cancel()
        callTask = Task { [weak self] in
            guard let self else { return }
            let positions: [AVAudio3DPoint] = [
                AVAudio3DPoint(x: 1.55, y: -0.5, z: -2.2),
                AVAudio3DPoint(x: -1.55, y: -0.5, z: -2.25),
                AVAudio3DPoint(x: 0.1, y: -0.5, z: -3.15)
            ]
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(index == 0 ? 4 : 12))
                guard !Task.isCancelled else { return }
                playCall(at: positions[index % positions.count])
                index += 1
            }
        }
    }

    private func playCall(at position: AVAudio3DPoint) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let buffer = makeBuffer(kind: .callForHelp, format: format, duration: 1.7) else { return }
        let player = AVAudioPlayerNode()
        player.position = position
        player.volume = 0.38
        player.renderingAlgorithm = .HRTFHQ
        engine.attach(player)
        engine.connect(player, to: environment, format: format)
        player.scheduleBuffer(buffer) { [weak self, weak player] in
            Task { @MainActor in
                guard let self, let player else { return }
                player.stop()
                self.engine.detach(player)
                self.players.removeAll { $0 === player }
            }
        }
        players.append(player)
        player.play()
    }

    private func makeBuffer(
        kind: SoundKind,
        format: AVAudioFormat,
        duration: TimeInterval
    ) -> AVAudioPCMBuffer? {
        let sampleRate = Float(format.sampleRate)
        let frameCount = AVAudioFrameCount(duration * Double(sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        var filteredNoise: Float = 0
        for frame in 0..<Int(frameCount) {
            let time = Float(frame) / sampleRate
            let random = Float.random(in: -1...1)
            filteredNoise += 0.025 * (random - filteredNoise)
            let value: Float
            switch kind {
            case .wind:
                let gust = 0.38 + 0.22 * sin(time * 0.55) + 0.12 * sin(time * 1.7)
                value = filteredNoise * max(0.1, gust)
            case .traffic:
                value = 0.42 * sin(2 * .pi * 47 * time)
                    + 0.18 * sin(2 * .pi * 83 * time)
                    + filteredNoise * 0.35
            case .siren:
                let sweep = 650 + 170 * sin(2 * .pi * 0.32 * time)
                value = 0.55 * sin(2 * .pi * sweep * time)
            case .leak:
                let pulse = pow(max(0, sin(2 * .pi * 1.6 * time)), 18)
                value = pulse * (0.55 * sin(2 * .pi * 135 * time) + random * 0.25)
            case .injuredVoice:
                let breath = max(0, sin(2 * .pi * 0.21 * time))
                value = breath * (0.35 * sin(2 * .pi * 118 * time) + filteredNoise * 0.28)
            case .callForHelp:
                let envelope = sin(.pi * min(1, time / Float(duration)))
                let syllable = max(0, sin(2 * .pi * 2.1 * time))
                let pitch = 165 + 22 * sin(2 * .pi * 1.05 * time)
                value = envelope * (0.5 + 0.5 * syllable)
                    * (0.58 * sin(2 * .pi * pitch * time) + 0.22 * sin(2 * .pi * pitch * 2 * time))
            }
            samples[frame] = tanh(value) * 0.7
        }
        return buffer
    }
}

private enum SoundKind {
    case wind
    case traffic
    case siren
    case leak
    case injuredVoice
    case callForHelp

    var duration: TimeInterval {
        switch self {
        case .wind, .traffic, .siren: 8
        case .leak: 3
        case .injuredVoice: 9
        case .callForHelp: 1.7
        }
    }
}
