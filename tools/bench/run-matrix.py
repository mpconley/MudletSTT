#!/usr/bin/env python3
"""Decode one recording under every configuration and write scoreable pairs.

Each configuration produces <out>/<name>.tsv of reference<TAB>heard lines, which
score.lua turns into the comparison table. Scoring lives in Lua on purpose: it
reuses sttpkg.test from the package itself, so a number here means the same
thing as a number from "stt test" in a live profile.
"""
import argparse, itertools, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sherpa_bench import decode, load_library, model_files, read_wav, SENSITIVITY


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lib", default=os.path.expanduser("~/.config/mudlet/sherpa-onnx-lib"))
    parser.add_argument("--models", default=os.path.expanduser("~/.config/mudlet/sherpa-models"),
                        help="directory of model directories, or one model directory")
    parser.add_argument("--wav", required=True)
    parser.add_argument("--refs", required=True, help="expected phrases, one per line, in spoken order")
    parser.add_argument("--hotwords", help="biasing words; each model runs with and without")
    parser.add_argument("--sensitivities", default="default",
                        help="comma-separated, or 'all'")
    parser.add_argument("--out", default="results")
    args = parser.parse_args()

    with open(args.refs, encoding="utf-8") as handle:
        refs = [line.strip() for line in handle if line.strip()]
    words = []
    if args.hotwords:
        with open(args.hotwords, encoding="utf-8") as handle:
            words = [w.strip().lower() for w in handle if w.strip()]

    models = [args.models] if os.path.exists(os.path.join(args.models, "tokens.txt")) else [
        os.path.join(args.models, n) for n in sorted(os.listdir(args.models))
        if os.path.isdir(os.path.join(args.models, n))]
    sensitivities = sorted(SENSITIVITY) if args.sensitivities == "all" \
        else args.sensitivities.split(",")

    lib = load_library(args.lib)
    samples = read_wav(args.wav)
    os.makedirs(args.out, exist_ok=True)

    biasings = [False, True] if words else [False]
    for model, sensitivity, biased in itertools.product(models, sensitivities, biasings):
        files = model_files(model)
        # A model with no bpe.vocab cannot bias at all, so its "biased" run
        # would be a duplicate of its plain one - and two identical runs
        # compared against each other invite a conclusion drawn from nothing.
        if biased and not files["bpe_vocab"]:
            continue
        name = "%s.%s.%s" % (os.path.basename(model.rstrip("/")), sensitivity,
                             "biased" if biased else "plain")
        started = time.monotonic()
        heard, applied = decode(lib, files, samples, words if biased else [],
                                sensitivity, 1.5)
        # Against the wall clock of the audio itself. Above 1.0 the model cannot
        # keep up with someone speaking, which no accuracy score would reveal.
        realtime = (time.monotonic() - started) / (len(samples) / 16000.0)
        with open(os.path.join(args.out, name + ".tsv"), "w", encoding="utf-8") as handle:
            handle.write("# biasing=%d utterances=%d expected=%d rtf=%.2f\n"
                         % (applied, len(heard), len(refs), realtime))
            for index, ref in enumerate(refs):
                handle.write("%s\t%s\n" % (ref, heard[index] if index < len(heard) else ""))
        note = "" if len(heard) == len(refs) else \
            "  <- heard %d utterances for %d phrases" % (len(heard), len(refs))
        print("%-72s %.2fx realtime%s" % (name, realtime, note))


if __name__ == "__main__":
    main()
