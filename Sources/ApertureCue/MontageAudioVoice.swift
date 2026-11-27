#if os(macOS)
import Foundation
import MappingCore

/// Owns one isolated production PCM adapter for the lifetime of an active clip.
/// The ordinary source's transport and route remain independent.
final class MontageAudioVoice {
    private struct Source: Equatable {
        let assetID: UUID
        let url: URL
        let revision: UUID
        let route: AudioRoutingSettings?
    }

    private struct Position: Equatable {
        let clip: MontageClip
        let montageCycle: Int
        let clipCycle: Int
        let serial: UInt64
    }

    private let factory: () -> MediaAudioPlayer
    private var player: MediaAudioPlayer?
    private var source: Source?
    private var position: Position?
    private var generation: UInt64 = 0
    private var preparing = false
    private var capacityUnavailable = false
    var assetID: UUID? { source?.assetID }

    init(factory: @escaping () -> MediaAudioPlayer) {
        self.factory = factory
    }

    func invalidate() {
        player?.invalidate()
        player = nil
        source = nil
        position = nil
        preparing = false
        capacityUnavailable = false
    }

    func update(_ leg: MontageLeg, url: URL, revision: UUID, montageCycle: Int, serial: UInt64, playing: Bool) -> String? {
        let clip = leg.clip
        let asset = leg.asset
        let nextSource = Source(assetID: asset.id, url: url, revision: revision, route: asset.audioRouting)
        if source != nextSource {
            invalidate()
            source = nextSource
        }
        if asset.audioRouting?.enabled == false { return nil }
        let nextPosition = Position(clip: clip, montageCycle: montageCycle, clipCycle: leg.clipCycle, serial: serial)
        if nextPosition != position {
            position = nextPosition
            generation &+= 1
        }
        if (player == nil || capacityUnavailable), MediaAudioPlayer.admittedSourceCount < MontagePool.maximumAudioVoices {
            let adapter = player ?? factory()
            player = adapter
            preparing = true
            capacityUnavailable = false
            adapter.prepare(url: url, routing: asset.audioRouting) { [weak self, weak adapter] result in
                guard let self, self.player === adapter else { return }
                self.preparing = false
                if case let .failure(error) = result {
                    self.capacityUnavailable = (error as? MediaAudioFailure)?.isAdmissionLimit == true
                }
            }
        }
        guard let player else { return "Routed audio capacity is in use" }
        guard player.ready else {
            // Selecting embedded audio on a silent movie is allowed, but must be visible.
            return preparing ? "Loading montage audio" : player.diagnostic
        }
        guard clip.sourceOut <= player.duration + 1e-6 else {
            player.stop()
            return "Montage audio Out exceeds the source duration"
        }
        player.update(positionSeconds: leg.sourceTime, playing: playing, rate: clip.rate,
                      generation: generation, volume: asset.volume * leg.weight, endSeconds: leg.audioEnd)
        return player.diagnostic
    }
}
#endif
