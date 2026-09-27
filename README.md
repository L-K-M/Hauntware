# Planchette

A cross-platform text editor for macOS, Windows, Linux, and Android. Built as
a sibling of [Séance](https://github.com/L-K-M/Seance) and
[Poltergeist](https://github.com/L-K-M/Poltergeist).

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*The pointer that spells it out.*

**Current version:** v<!-- version -->0.1.0<!-- /version --> · [Releases](https://github.com/L-K-M/Planchette/releases)

## Status

Scaffolding. The pure-Dart core lives in `packages/`; the Flutter client will
live at `app/planchette_app` (not yet scaffolded — see AGENTS.md for the
layout and the reasons behind it).

## Build

Requires the Dart SDK (3.12+) for the pure-Dart packages and Flutter 3.47.2
for the app, once it exists.

```bash
dart pub get
dart analyze packages/planchette_core
dart test    packages/planchette_core

# Every target this host can build, staged into dist/
scripts/build.sh
```
