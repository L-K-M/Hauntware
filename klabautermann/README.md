# Klabautermann

An agentless fleet manager for servers and Docker over SSH: monitor
hosts, read the Docker Engine, and run previewed, confirmed operations.
The fourth Hauntware product, a sibling of
[Séance](https://github.com/L-K-M/Seance),
[Planchette](https://github.com/L-K-M/Planchette) and Poltergeist.

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*The kobold that keeps the ship's engines lit.*

**Current version:** v<!-- version -->1.9.3<!-- /version -->

## Where things stand

Klabautermann reaches v1's feature set as a preview: suite releases ship
its five clients (macOS, Windows, Linux, Android, and an unsigned iOS
build check) as `klabautermann-preview-*` assets until v1 is signed off.
It reads hosts (metrics, processes, services, logs, jobs, disks, network,
hardware, updates, users) and the Docker Engine over SSH, runs previewed
and confirmed actions with admin mode for root, edits files with a diff
and a backup, raises alerts while it is open, and shares servers with Séance and
Poltergeist, and its own alert rules and preferences between your
devices, through the suite's sync server.

- [docs/INSTALL.md](docs/INSTALL.md): downloading, verifying and the
  first launch on each platform.
- [docs/COVERAGE.md](docs/COVERAGE.md): what Klabautermann watches, when,
  and what it cannot see while it is closed.
- [docs/STATUS.md](docs/STATUS.md): what is on main, each milestone's
  exit evidence and the manual checks still open.

Implementation follows
[`../docs/design/klabautermann/`](../docs/design/klabautermann/); the
decision log is `03-ARCHITECTURE.md` section 2 and the milestone plan is
`04-IMPLEMENTATION.md` section 13. The working guide for agents and
contributors is [`AGENTS.md`](AGENTS.md).

## License

Klabautermann's own code uses the [Unlicense](LICENSE). The bundled
third-party code keeps its own licenses; see the suite's
[License section](../README.md#license).
