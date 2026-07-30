import AVFoundation
import Foundation
import Observation

/// Toca um segmento e informa qual palavra está sendo pronunciada.
///
/// O tempo vem do `AVAudioPlayer`, não de um relógio próprio: qualquer deriva entre
/// contador e áudio apareceria como o destaque descolando da voz ao longo do parágrafo.
@MainActor
@Observable
final class SegmentPlayer {

    private(set) var isPlaying = false
    /// Range da palavra atual **no texto normalizado** do segmento. Quem desenha o
    /// destaque ainda precisa traduzi-lo para os índices da página.
    private(set) var currentWordRange: NSRange?

    /// Chamado quando o segmento termina sozinho (não em pausa nem em troca).
    var onFinish: (() -> Void)?

    private var player: AVAudioPlayer?
    private var alignment: SegmentAlignmentSnapshot?
    private var ticker: Timer?

    struct SegmentAlignmentSnapshot {
        let words: [(range: NSRange, start: TimeInterval)]
        let duration: TimeInterval

        func range(at time: TimeInterval) -> NSRange? {
            index(at: time).map { words[$0].range }
        }

        private func index(at time: TimeInterval) -> Int? {
            guard time >= 0, time <= duration, !words.isEmpty else { return nil }
            var low = 0, high = words.count - 1, found: Int?
            while low <= high {
                let mid = (low + high) / 2
                if words[mid].start <= time { found = mid; low = mid + 1 } else { high = mid - 1 }
            }
            return found
        }
    }

    func play(url: URL, alignment: SegmentAlignmentSnapshot, from startTime: TimeInterval = 0) {
        stop()

        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        self.alignment = alignment

        player.prepareToPlay()
        // Começar onde o leitor tocou aproveita o áudio do trecho inteiro já em cache.
        if startTime > 0, startTime < alignment.duration {
            player.currentTime = startTime
        }
        player.play()
        isPlaying = true

        // 20 Hz basta: a palavra mais curta medida dura ~60 ms, e um timer mais rápido
        // só gastaria bateria.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func resume() {
        guard let player else { return }
        player.play()
        isPlaying = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        alignment = nil
        isPlaying = false
        currentWordRange = nil
    }

    private func tick() {
        guard let player, let alignment else { return }

        currentWordRange = alignment.range(at: player.currentTime)

        if !player.isPlaying {
            let finished = player.currentTime >= alignment.duration - 0.1
            ticker?.invalidate()
            ticker = nil
            isPlaying = false
            if finished { onFinish?() }
        }
    }
}
