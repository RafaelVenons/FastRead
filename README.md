# FastRead

Leitor de PDF para iPad que lê um trecho em voz alta e destaca o texto **palavra a palavra**, em sincronia com a voz. Um toque no parágrafo começa a leitura: se o áudio ainda não existe, é gerado na hora; se já existe, carrega do cache.

Tudo roda **no dispositivo, offline**. Sem servidor, sem chave de API, sem enviar o documento para lugar nenhum.

## Como o alinhamento funciona

O plano original era usar o [Montreal Forced Aligner](https://montreal-forced-aligner.readthedocs.io/) para alinhar áudio e texto. **MFA não roda em iPadOS** (é Python/Kaldi) — e não precisa: o `AVSpeechSynthesizer` já emite markers de palavra durante a síntese, com o offset de cada uma no áudio. É alinhamento forçado nativo, de graça e offline.

Três armadilhas foram medidas na prática e estão cobertas por teste:

| Armadilha | Sintoma se ignorada |
|---|---|
| `byteSampleOffset` é medido em **bytes**, não em samples | Todos os tempos 4× maiores (um áudio de 5,42 s marcava a última palavra em 18,3 s) |
| O parâmetro `toMarkerCallback:` de `write(_:toBufferCallback:toMarkerCallback:)` **não dispara** | Zero markers; use o delegate `speechSynthesizer(_:willSpeak:utterance:)` |
| O buffer final chega **duas vezes** (`frameLength == 0`) | Cada segmento gravado no cache em duplicidade |

E duas do lado do PDF:

- **O PDFKit colapsa linhas em branco**: um `\n\n` do documento chega como `\n`. Segmentar por linha em branco faria o documento inteiro virar um único segmento — o limite de parágrafo usa pontuação final.
- **Normalizar o texto desalinha o destaque**: unir linhas e resolver hifenização muda os índices, então `MappedSegment` carrega a rota de volta para as posições da página.

## Números medidos

| | |
|---|---|
| Velocidade de síntese | ~39× tempo real (M2); ~24× estimado no M1 do iPad Air 5 |
| Custo de pré-gerar o próximo trecho | ~4% da duração do trecho atual |
| Áudio em AAC 24 kbps | 17 MB/hora — contra 311 MB/hora do PCM que sai do sintetizador |
| Livro de ~8 h de leitura | ~136 MB em cache, contra ~2,5 GB sem compressão |
| Detecção de idioma | ~6 ms por trecho |

## Estrutura

```
Sources/FastReadCore/      núcleo testável, sem UI
  LanguageDetector         idioma do documento e por trecho
  TextSegmenter            texto de PDF → trechos + mapa de índices
  DocumentSegmenter        PDF → segmentos localizados
  SpeechSynthesisEngine    síntese + markers → AAC
  AlignmentBuilder         markers → tempos por palavra
  SegmentCache             .m4a + .json em disco, com prune LRU
  SegmentPipeline          cache, coalescing e prefetch

App/Sources/               app iPad (SwiftUI + PDFKit)
Tests/FastReadCoreTests/   97 testes
```

O núcleo é um Swift Package para que os testes rodem em ~3 s sem simulador. O app depende dele.

## Rodando

```bash
swift test                 # 97 testes, ~3s
xcodegen generate          # gera FastRead.xcodeproj a partir de project.yml
open FastRead.xcodeproj
```

O `.xcodeproj` não é versionado — é derivado de `project.yml`.

## Qualidade da voz

O sistema traz apenas vozes `compact` por padrão, que soam robóticas. As `enhanced`/`premium` são bem melhores e ficam em **Ajustes → Acessibilidade → Conteúdo Falado → Vozes**. É a maior melhoria de qualidade disponível, e não custa nada em código.

## Próximos passos

- Anotações com Apple Pencil (`PKCanvasView` sobre cada `PDFPage`, com `isInMarkupMode`)
- Biblioteca de documentos com posição de leitura salva
- Prune automático do cache por limite configurável
