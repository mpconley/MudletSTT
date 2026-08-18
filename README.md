# MudletSTT

Speech-to-text for [Mudlet](https://www.mudlet.org/), built on the `stt.*`
speech bridge. Toggle the microphone, speak, and your words land in the
command line ready to send — corrected against the game's own vocabulary
when the game publishes one.

## What it does

- **Toggle listening** with the `stt` alias, or the microphone toolbar
  button on Mudlet builds that provide the addon toolbar API.
- **Command-line routing**: partial results preview live in the command
  line while you speak; each finished utterance replaces the line, ready
  for Return. `stt autosend on` sends utterances straight to the game
  instead.
- **Vocabulary correction**: when the
  [MudletMCVP](https://github.com/mpconley/MudletMCVP) package is installed
  and the game implements the
  [MUD Client Vocabulary Protocol](https://wiki.mudlet.org/w/Standards:MUD_Client_Vocabulary_Protocol),
  recognised words are corrected against the game's command and target
  vocabulary. Corrections are conservative: only a unique, close match
  within a length-scaled edit distance replaces a word.
- **Typed the way you'd type it**: recognisers that produce natural prose
  sentence-case their output ("Smile"), so the first letter is lowercased to
  match how commands are written. Only the first letter — proper nouns in
  arguments keep their case.
- **Tuned for commands, not dictation**: sensitivity defaults to `short`, so a
  one-word command like `look` commits after a brief pause instead of waiting
  out a dictation-length silence. Engines that support it are also biased
  against dropping the quiet start of a phrase, which is where the verb lives.
- **Engine aware**: prefers an installed sherpa-onnx streaming model
  (NVIDIA Nemotron - high accuracy, hands-free endpointing) and falls back
  to Vosk. Models install separately via engine packs.

## Commands

```
stt              toggle listening (also: stt on / stt off)
stt status       engine, state and settings
stt autosend on|off    send finals to the game instead of the command line
stt preview on|off     show partial results live in the command line
stt correct on|off     correct finals against the game vocabulary (MCVP)
stt lowercase on|off   lowercase the first letter, the way commands are typed
stt sensitivity short|default|long   how soon a phrase counts as finished
stt timeout <ms>       stop after this much silence; 0 keeps listening
stt models       list installed speech models
```

## Events

| Event | Arguments | When |
| --- | --- | --- |
| `sttPackageResult` | corrected text, raw text | Each finished utterance, after correction. |
| `sttPackageState` | state string | The recogniser changed state. |

Other packages can consume these instead of the raw `sysSTT*` events to get
correction for free.

## Requirements

- A Mudlet build with the `stt.*` speech bridge.
- An installed speech model (sherpa-onnx or Vosk). The package tells you
  where models belong (`stt.getModelPath()`) when none is found.
- Optional: MudletMCVP + a game that implements Client.Vocabulary, for
  correction.

## Development

Scripts live under `src/scripts/STT/`; the correction engine
(`STTCorrect.lua`) is pure Lua and tested with
[busted](https://lunarmodules.github.io/busted/): `busted spec`. Builds use
[muddler](https://github.com/demonnic/muddler).
