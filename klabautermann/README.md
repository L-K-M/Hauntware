# Klabautermann

An agentless fleet manager for servers and Docker over SSH: monitor
hosts, read the Docker Engine, and run previewed, confirmed operations.
The fourth Hauntware product, a sibling of
[Séance](https://github.com/L-K-M/Seance),
[Planchette](https://github.com/L-K-M/Planchette) and Poltergeist.

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*The kobold that keeps the ship's engines lit.*

**Current version:** v<!-- version -->1.9.0<!-- /version -->

## Where things stand

Klabautermann is a scaffold: the pure-Dart packages
(`klabautermann_host`, `klabautermann_docker`, `klabautermann_core`)
carry the collector parsers, the Docker client and the engine-isolate
protocol, and the app carries its adaptive shell, themes and settings
route. Nothing connects to a host yet; that lands with the transport
milestone (M2). Implementation follows
[`../docs/design/klabautermann/`](../docs/design/klabautermann/); the
decision log is `03-ARCHITECTURE.md` section 2 and the milestone plan is
`04-IMPLEMENTATION.md` section 13. Current state and open manual checks
live in [`docs/STATUS.md`](docs/STATUS.md); the working guide for agents
and contributors is [`AGENTS.md`](AGENTS.md).
