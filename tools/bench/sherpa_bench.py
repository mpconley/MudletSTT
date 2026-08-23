#!/usr/bin/env python3
"""Decode one recording with one sherpa-onnx configuration.

The point is a measurement that does not need a person: speak the phrases once,
then run every model, sensitivity and biasing setting against that same audio.
Two spoken runs never hear the same utterance twice, so every comparison built
from them carries the speaker's own variation - volume, pace, practice - inside
the difference it reports. One recording removes that by construction.

Audio is fed through the streaming API in 50ms chunks, the way the microphone
feeds it in Mudlet, and utterances are cut where the library's endpointer says
so. Decoding the file in one call would be simpler and would measure the wrong
thing: endpointing is where a phrase loses its first word.

Struct layouts are vendored from sherpa-onnx v1.13.5 c-api.h, matching
src/SherpaRecognizer.cpp. Re-check them against that file after a library
upgrade; a silently wrong layout reads garbage rather than failing.
"""
import argparse, ctypes, json, os, sys, wave

CHUNK_MS = 50
SAMPLE_RATE = 16000

c_char_p, c_int32, c_float = ctypes.c_char_p, ctypes.c_int32, ctypes.c_float


class Transducer(ctypes.Structure):
    _fields_ = [("encoder", c_char_p), ("decoder", c_char_p), ("joiner", c_char_p)]


class Paraformer(ctypes.Structure):
    _fields_ = [("encoder", c_char_p), ("decoder", c_char_p)]


class Zipformer2Ctc(ctypes.Structure):
    _fields_ = [("model", c_char_p)]


class NemoCtc(ctypes.Structure):
    _fields_ = [("model", c_char_p)]


class ToneCtc(ctypes.Structure):
    _fields_ = [("model", c_char_p)]


class ModelConfig(ctypes.Structure):
    _fields_ = [
        ("transducer", Transducer), ("paraformer", Paraformer),
        ("zipformer2_ctc", Zipformer2Ctc), ("tokens", c_char_p),
        ("num_threads", c_int32), ("provider", c_char_p), ("debug", c_int32),
        ("model_type", c_char_p), ("modeling_unit", c_char_p),
        ("bpe_vocab", c_char_p), ("tokens_buf", c_char_p),
        ("tokens_buf_size", c_int32), ("nemo_ctc", NemoCtc), ("t_one_ctc", ToneCtc),
    ]


class FeatureConfig(ctypes.Structure):
    _fields_ = [("sample_rate", c_int32), ("feature_dim", c_int32)]


class CtcFstDecoderConfig(ctypes.Structure):
    _fields_ = [("graph", c_char_p), ("max_active", c_int32)]


class HomophoneReplacerConfig(ctypes.Structure):
    _fields_ = [("dict_dir", c_char_p), ("lexicon", c_char_p), ("rule_fsts", c_char_p)]


class RecognizerConfig(ctypes.Structure):
    _fields_ = [
        ("feat_config", FeatureConfig), ("model_config", ModelConfig),
        ("decoding_method", c_char_p), ("max_active_paths", c_int32),
        ("enable_endpoint", c_int32), ("rule1_min_trailing_silence", c_float),
        ("rule2_min_trailing_silence", c_float), ("rule3_min_utterance_length", c_float),
        ("hotwords_file", c_char_p), ("hotwords_score", c_float),
        ("ctc_fst_decoder_config", CtcFstDecoderConfig), ("rule_fsts", c_char_p),
        ("rule_fars", c_char_p), ("blank_penalty", c_float),
        ("hotwords_buf", c_char_p), ("hotwords_buf_size", c_int32),
        ("hr", HomophoneReplacerConfig),
    ]


class Result(ctypes.Structure):
    _fields_ = [
        ("text", c_char_p), ("tokens", c_char_p),
        ("tokens_arr", ctypes.POINTER(c_char_p)), ("timestamps", ctypes.POINTER(c_float)),
        ("count", c_int32), ("json", c_char_p),
    ]


# Same three profiles SherpaRecognizer applies; Default leaves zeroes so the
# library's own 2.4/1.2/20 defaults stand.
SENSITIVITY = {"default": None, "short": (1.0, 0.6, 15.0), "long": (3.6, 2.0, 30.0)}


def load_library(lib_dir):
    onnx = os.path.join(lib_dir, "libonnxruntime.dylib")
    if os.path.exists(onnx):
        ctypes.CDLL(onnx, mode=ctypes.RTLD_GLOBAL)
    lib = ctypes.CDLL(os.path.join(lib_dir, "libsherpa-onnx-c-api.dylib"))
    lib.SherpaOnnxCreateOnlineRecognizer.restype = ctypes.c_void_p
    lib.SherpaOnnxCreateOnlineRecognizer.argtypes = [ctypes.c_void_p]
    lib.SherpaOnnxCreateOnlineStream.restype = ctypes.c_void_p
    lib.SherpaOnnxCreateOnlineStream.argtypes = [ctypes.c_void_p]
    lib.SherpaOnnxOnlineStreamAcceptWaveform.argtypes = [
        ctypes.c_void_p, c_int32, ctypes.POINTER(c_float), c_int32]
    lib.SherpaOnnxIsOnlineStreamReady.restype = c_int32
    lib.SherpaOnnxIsOnlineStreamReady.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.SherpaOnnxDecodeOnlineStream.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.SherpaOnnxGetOnlineStreamResult.restype = ctypes.POINTER(Result)
    lib.SherpaOnnxGetOnlineStreamResult.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.SherpaOnnxDestroyOnlineRecognizerResult.argtypes = [ctypes.POINTER(Result)]
    lib.SherpaOnnxOnlineStreamIsEndpoint.restype = c_int32
    lib.SherpaOnnxOnlineStreamIsEndpoint.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.SherpaOnnxOnlineStreamReset.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.SherpaOnnxOnlineStreamInputFinished.argtypes = [ctypes.c_void_p]
    lib.SherpaOnnxDestroyOnlineStream.argtypes = [ctypes.c_void_p]
    lib.SherpaOnnxDestroyOnlineRecognizer.argtypes = [ctypes.c_void_p]
    return lib


def model_files(model_dir):
    """Same layout rule SherpaRecognizer uses: tokens.txt plus encoder, decoder
    and joiner .onnx. int8 variants win where a model ships both."""
    def pick(prefix):
        names = sorted(n for n in os.listdir(model_dir)
                       if n.startswith(prefix) and n.endswith(".onnx"))
        if not names:
            return None
        int8 = [n for n in names if "int8" in n]
        return os.path.join(model_dir, (int8 or names)[0])

    tokens = os.path.join(model_dir, "tokens.txt")
    files = {p: pick(p) for p in ("encoder", "decoder", "joiner")}
    if not os.path.exists(tokens) or not all(files.values()):
        sys.exit("not a sherpa-onnx streaming model: %s" % model_dir)
    files["tokens"] = tokens
    bpe = os.path.join(model_dir, "bpe.vocab")
    files["bpe_vocab"] = bpe if os.path.exists(bpe) else None
    return files


def tokens_are_uppercase(tokens_path):
    """A lowercase hotword against an uppercase-token model tokenises to
    something never scored, so the bias silently does nothing."""
    upper = lower = 0
    with open(tokens_path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            piece = line.split(" ")[0].lstrip("▁")
            for char in piece:
                if char.isupper():
                    upper += 1
                elif char.islower():
                    lower += 1
    return upper > lower


def read_wav(path):
    with wave.open(path, "rb") as handle:
        if handle.getnchannels() != 1 or handle.getsampwidth() != 2 \
                or handle.getframerate() != SAMPLE_RATE:
            sys.exit("need mono 16-bit %dHz wav: %s" % (SAMPLE_RATE, path))
        raw = handle.readframes(handle.getnframes())
    ints = ctypes.cast(raw, ctypes.POINTER(ctypes.c_int16))
    count = len(raw) // 2
    return [ints[i] / 32768.0 for i in range(count)]


def split_on_silence(samples, expected):
    """Cut the recording into exactly `expected` segments, at its longest pauses.

    Letting the library's endpointer do the cutting looked simpler and was
    wrong: models endpoint differently, so two configurations merge different
    pairs of phrases and every reference after a merge lines up against the
    wrong utterance. Cutting once, here, gives every configuration the same
    segments to be judged on.

    Cutting at a fixed silence length was the next wrong answer - the pause
    inside "get newspaper" and the pause between two phrases are not reliably
    different, and no single threshold separates them for every speaker. So the
    count does the work instead: eight phrases means seven boundaries, which are
    the seven longest silences in the recording, wherever they fall.
    """
    frame = SAMPLE_RATE // 100  # 10ms
    energies = [sum(abs(v) for v in samples[at:at + frame]) / frame
                for at in range(0, len(samples) - frame, frame)]
    if not energies or expected < 1:
        return []

    ordered = sorted(energies)
    quiet = ordered[len(ordered) // 10]
    loud = ordered[-max(1, len(ordered) // 10)]
    threshold = max(quiet * 3.0, quiet + (loud - quiet) * 0.06)

    # A breath or a click inside a pause is not speech, and counting it as
    # speech splits one long silence into two shorter ones - after which the
    # longest-gaps rule below picks both halves of one pause and misses another
    # pause entirely. Runs under 80ms are read as part of the silence.
    speech = [energy > threshold for energy in energies]
    index = 0
    while index < len(speech):
        if speech[index]:
            end = index
            while end < len(speech) and speech[end]:
                end += 1
            if end - index < 8:
                for at in range(index, end):
                    speech[at] = False
            index = end
        else:
            index += 1

    runs, run_start = [], None
    for index, loud_enough in enumerate(speech):
        if not loud_enough:
            if run_start is None:
                run_start = index
        elif run_start is not None:
            runs.append((run_start, index))
            run_start = None
    if run_start is not None:
        runs.append((run_start, len(energies)))
    # Leading and trailing silence bound the speech, they do not divide it
    inner = [r for r in runs if r[0] > 0 and r[1] < len(energies)]

    inner.sort(key=lambda r: r[1] - r[0], reverse=True)
    cuts = sorted((first + last) // 2 for first, last in inner[:expected - 1])

    bounds = [0] + [c * frame for c in cuts] + [len(samples)]
    return [samples[bounds[i]:bounds[i + 1]] for i in range(len(bounds) - 1)]


def decode(lib, files, samples, hotwords, sensitivity, hotwords_score, segments=None):
    # The struct goes inside a larger zeroed block for the same reason
    # SherpaRecognizer does it: a newer library reads fields appended after
    # this layout, and zeros make it substitute its own defaults.
    block = ctypes.create_string_buffer(ctypes.sizeof(RecognizerConfig) * 4)
    config = ctypes.cast(block, ctypes.POINTER(RecognizerConfig)).contents

    keep = [f.encode() for f in
            (files["encoder"], files["decoder"], files["joiner"], files["tokens"])]
    config.model_config.transducer.encoder = keep[0]
    config.model_config.transducer.decoder = keep[1]
    config.model_config.transducer.joiner = keep[2]
    config.model_config.tokens = keep[3]
    # Both are load-bearing and neither is a library default: a zeroed
    # enable_endpoint means no endpointing at all, and the whole recording comes
    # back as one run-on utterance.
    config.model_config.num_threads = 2
    config.enable_endpoint = 1

    rules = SENSITIVITY[sensitivity]
    if rules:
        (config.rule1_min_trailing_silence, config.rule2_min_trailing_silence,
         config.rule3_min_utterance_length) = rules

    applied = 0
    if hotwords and files["bpe_vocab"]:
        words = hotwords
        if tokens_are_uppercase(files["tokens"]):
            words = [w.upper() for w in words]
        buf = "\n".join(words).encode()
        keep += [files["bpe_vocab"].encode(), b"bpe", b"modified_beam_search", buf]
        config.model_config.modeling_unit = keep[-3]
        config.model_config.bpe_vocab = keep[-4]
        config.decoding_method = keep[-2]
        config.hotwords_buf = keep[-1]
        config.hotwords_buf_size = len(buf)
        config.hotwords_score = hotwords_score
        applied = len(words)

    recognizer = lib.SherpaOnnxCreateOnlineRecognizer(ctypes.byref(config))
    if not recognizer:
        sys.exit("the library refused this configuration")

    step = SAMPLE_RATE * CHUNK_MS // 1000
    # Half a second of digital silence after each segment, so the endpointer
    # commits the utterance the way trailing silence in a recording would.
    silence = [0.0] * (SAMPLE_RATE // 2)

    def run(audio):
        """Everything one segment decodes to, as a single line."""
        stream = lib.SherpaOnnxCreateOnlineStream(recognizer)
        parts = []

        def collect():
            while lib.SherpaOnnxIsOnlineStreamReady(recognizer, stream):
                lib.SherpaOnnxDecodeOnlineStream(recognizer, stream)
            if lib.SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream):
                result = lib.SherpaOnnxGetOnlineStreamResult(recognizer, stream)
                text = (result.contents.text or b"").decode(errors="replace").strip()
                lib.SherpaOnnxDestroyOnlineRecognizerResult(result)
                if text:
                    parts.append(text)
                lib.SherpaOnnxOnlineStreamReset(recognizer, stream)

        for offset in range(0, len(audio), step):
            chunk = audio[offset:offset + step]
            buf = (c_float * len(chunk))(*chunk)
            lib.SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, buf, len(chunk))
            collect()
        buf = (c_float * len(silence))(*silence)
        lib.SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, buf, len(silence))
        collect()

        lib.SherpaOnnxOnlineStreamInputFinished(stream)
        while lib.SherpaOnnxIsOnlineStreamReady(recognizer, stream):
            lib.SherpaOnnxDecodeOnlineStream(recognizer, stream)
        result = lib.SherpaOnnxGetOnlineStreamResult(recognizer, stream)
        tail = (result.contents.text or b"").decode(errors="replace").strip()
        lib.SherpaOnnxDestroyOnlineRecognizerResult(result)
        if tail:
            parts.append(tail)
        lib.SherpaOnnxDestroyOnlineStream(stream)
        return " ".join(parts).strip()

    if segments:
        # A fresh stream per segment: one segment in, one line out, whatever the
        # endpointer decided inside it. Alignment with the references then
        # cannot drift, which is the whole reason the audio is cut up first.
        utterances = [run(segment) for segment in segments]
    else:
        text = run(samples)
        utterances = [text] if text else []

    lib.SherpaOnnxDestroyOnlineRecognizer(recognizer)
    return utterances, applied


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lib", default=os.path.expanduser("~/.config/mudlet/sherpa-onnx-lib"))
    parser.add_argument("--model", required=True)
    parser.add_argument("--wav", required=True)
    parser.add_argument("--hotwords", help="file of biasing words, one per line")
    parser.add_argument("--hotwords-score", type=float, default=1.5)
    parser.add_argument("--sensitivity", choices=sorted(SENSITIVITY), default="default")
    parser.add_argument("--segments", type=int, default=0,
                        help="split the recording into this many phrases at the silences")
    args = parser.parse_args()

    words = []
    if args.hotwords:
        with open(args.hotwords, encoding="utf-8") as handle:
            words = [w.strip().lower() for w in handle if w.strip()]

    lib = load_library(args.lib)
    files = model_files(args.model)
    samples = read_wav(args.wav)
    segments = split_on_silence(samples, args.segments) if args.segments else None
    if segments is not None and len(segments) != args.segments:
        sys.exit("split the recording into %d segments, expected %d - adjust the "
                 "pauses or the gap threshold" % (len(segments), args.segments))
    utterances, applied = decode(lib, files, samples, words,
                                 args.sensitivity, args.hotwords_score, segments)
    json.dump({"model": os.path.basename(args.model.rstrip("/")),
               "sensitivity": args.sensitivity,
               "biasing": applied,
               "biasable": bool(files["bpe_vocab"]),
               "utterances": utterances}, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
