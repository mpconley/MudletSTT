# Batch bench

Speak the phrases once, then score every model, sensitivity and biasing setting
against that one recording.

`_pass.compare()` in the profile speaks each phrase list twice, so its two
conditions never hear the same utterance. Volume, pace, practice and the mic
warming up all live inside the difference it reports, and separating them costs
another twenty minutes of talking per question. Decoding one recording N ways
removes that by construction: the audio is byte-identical, so a difference is
the decoder's.

It is not a replacement for `_pass.compare()`. This measures the engine on fixed
audio; the live harness measures the whole path, including whatever the package
did with the words afterwards. Use this to choose a model, then confirm live.

## Recording

Anything that produces mono 16-bit 16kHz WAV. With ffmpeg on macOS:

    ffmpeg -f avfoundation -i ":default" -ac 1 -ar 16000 -sample_fmt s16 phrases.wav

Say each phrase with **at least 1.5 seconds of silence between them**, and leave
two seconds at the end. The default endpointer needs 1.2s of trailing silence to
call an utterance finished, so shorter gaps run phrases together and every
configuration then scores against misaligned references. Leave a moment of
silence at the start too - the first phrase is the one most often clipped.

Write the phrases in spoken order to a references file, one per line.

`say -o phrases.wav --data-format=LEI16@16000 --file-format=WAVE "..."` will
generate audio for checking the harness runs, but it is not a measurement:
synthesised speech has none of the variation the models are being judged on.

## Running

    python3 run-matrix.py --wav phrases.wav --refs refs.txt --hotwords words.txt --out results
    lua score.lua results/*.tsv

Each model runs with and without biasing, skipping the biased pass for models
that cannot bias - those have no `bpe.vocab`, and a biased run that applied
nothing is just a second plain run inviting a conclusion drawn from noise.
`--sensitivities all` adds the short and long endpointer profiles.

One configuration on its own:

    python3 sherpa_bench.py --model ~/.config/mudlet/sherpa-models/<name> --wav phrases.wav

## Reading the output

`realtime` is decode time over audio duration. **Above 1.00x the model cannot
keep up with someone speaking**, and no accuracy column shows that - a model can
score perfectly here and still fall behind a live microphone. Treat it as an
upper bound rather than a precise figure: the chunk marshalling in Python costs
something Mudlet does not pay.

`lost1` counts phrases whose first word went missing, which is usually an
endpointing symptom rather than a decoding one, and `blank` counts phrases that
came back empty - if that is not zero, check the pause length in the recording
before reading anything else.

Scoring is `sttpkg.test.score` from the package itself, so these numbers mean
what `stt test` means in a live profile.

## After a library upgrade

The struct layouts in `sherpa_bench.py` are vendored from sherpa-onnx v1.13.5,
matching `src/SherpaRecognizer.cpp`. Check them against that file after
upgrading the library: a wrong layout reads garbage rather than failing, and
`enable_endpoint` and `num_threads` are set explicitly because their zero values
are meaningful rather than absent.
