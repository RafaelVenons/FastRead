import AVFoundation
import SwiftUI

@main
struct FastReadApp: App {

    init() {
        // .playback mantém o áudio tocando com a tela bloqueada e ignora o botão de mudo,
        // que é o comportamento esperado de um leitor de livros.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ReaderView()
        }
    }
}
