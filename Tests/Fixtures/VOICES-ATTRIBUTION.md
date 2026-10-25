# VOiCES test fixture attribution

File: voices-source.wav (original filename Lab41-SRI-VOiCES-src-sp0307-ch127535-sg0042.wav)

Source download: https://download.pytorch.org/torchaudio/tutorial-assets/Lab41-SRI-VOiCES-src-sp0307-ch127535-sg0042.wav

Dataset creators: SRI International and Lab41, In-Q-Tel. VOiCES corpus (Richey et al., 2018).

Dataset/license primary source: https://iqtlabs.github.io/voices/

License: Creative Commons Attribution 4.0 International, https://creativecommons.org/licenses/by/4.0/ . The dataset authors explicitly describe the corpus as CC BY 4.0. PyTorch's official tutorial also identifies this speech fixture and license: https://docs.pytorch.org/audio/0.10.0/tutorials/audio_io_tutorial.html .

Original WAV SHA256: C65FCD726D6B08C82C1E5DC7558F863CD8D483E3ED2F4A7BCF271DC1865ADA14.

The original file is unchanged. Tests normalize its level, create synthetic background noise and tones, mix them, and create speech-subtracted derivative WAVs for implementation/effect diagnostics. These changes are not endorsed by SRI, Lab41 or PyTorch. This is English read speech, not Chinese LOL commentary, and is not known to be absent from the model's training corpus.

This copy is an iOS XCTest fixture only. It must not be included in the main IPA/app resources. Include this attribution when redistributing the test/source package or output examples.
