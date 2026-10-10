# 05. Names

Status: proposal for owner review, 2026-10-10.

The product is unnamed. The other chapters use the placeholders `<App>`
(display name) and `<app>` (lowercase ASCII stem for packages, ids and host
artifacts). This chapter derives naming rules from the three existing
products, recommends a name with two alternates, and records the collision
screen behind the recommendation. The screen ran on 2026-10-10. It is a
collision screen, not trademark clearance: no EU, German or French register
query ran (section 8).

The name feeds every identity in
[04-IMPLEMENTATION.md](04-IMPLEMENTATION.md), section 12.3, and decision D38
in [03-ARCHITECTURE.md](03-ARCHITECTURE.md) fixes those identities before
M1. Choosing it is open question 1 in 04, section 15. Decision numbers refer
to 03 unless they are marked as Poltergeist's. Report markers such as c4
refer to the appendices under [research/](research/README.md).

---

## 1. The suite's naming logic

Sources: the root `README.md`, `seance/AGENTS.md` (Name), Poltergeist's plan
(`poltergeist/docs/plan/00-OVERVIEW.md` D24 and
`poltergeist/docs/plan/01-PRODUCT.md` personality and voice) and the product
READMEs.

| Product | Origin | Spirit meaning | Function pun | Tagline |
| --- | --- | --- | --- | --- |
| Planchette | French, "little plank" | Pointer for automatic writing | Text editor | "The pointer that spells it out." |
| Séance | French, "a sitting" | Session with spirits | SSH session client | "You summon remote machines and talk to them." |
| Poltergeist | German, *poltern* + *Geist*, "noisy ghost" | Spirit that moves objects | File transfer | "The ghost that moves your files." |

Rules derived from these names and the repository:

1. **One word from spiritualism or haunting lore, with a literal function
   pun.** All three are distinctive foreign words that English speakers
   still recognise, which keeps them searchable. Common English words
   (Familiar, Sitter, Cabinet, Slate, Vigil) lose that and are harder to find
   in app stores and search.
2. **Friendly register.** Poltergeist's plan sets it as "Casper, not
   Poltergeist-the-film": a friendly ghost doing a job. Horror, death and
   gore read badly on a tool people open during an outage.
3. **Puns are seasoning, not structure** (Poltergeist's voice rules,
   `poltergeist/docs/plan/01-PRODUCT.md`). Feature names inside the app
   (Logs, Containers, Cron) stay literal; the pun lives in the name, the icon
   and one tagline.
4. **French and German balance.** Today two names are French and one is
   German. A German fourth name makes it 2:2, a French one 3:1. Either is
   consistent. Latin or an English coinage breaks the loanword pattern.
5. **ASCII file and bundle names.** macOS codesign rejects accented file
   names. Séance keeps `PRODUCT_NAME` as ASCII `Seance`, and
   `scripts/build.sh` renames the signed bundle to `Séance.app` when staging
   or installing; the accented form appears only in the display name
   (Android label, macOS `CFBundleName` and `CFBundleDisplayName`;
   `seance/AGENTS.md:250-254`). Poltergeist avoids the issue by being ASCII
   (`poltergeist/AGENTS.md:161-163`). A name with umlauts or accents needs a
   clean ASCII stem for `<app>`.
6. **Owned package names must not collide with dependency names.** The
   release tool rewrites the version pin of every lockfile entry whose name
   matches an owned package, whatever its source (`_rewriteLockPins`,
   `tool/release_version/lib/release_version.dart:85-104`), and `_checkLocks`
   (`:608`) fails the version check when such an entry is not at the suite
   version. If an owned package shared its name with a pub.dev package that
   some lockfile resolves, the release would overwrite that dependency's pin
   [R: c4 §2]. Only an exact name match triggers this; a shared prefix only
   confuses people. The screen therefore queried pub.dev for each
   candidate's planned package names (section 3).
7. **Collisions outside the category are acceptable, inside it they are
   not.** Poltergeist's decision D24 kept its name despite known collisions
   in unrelated categories: acceptable for a personal open-source app, but
   noted (`poltergeist/docs/plan/00-OVERVIEW.md:1107-1111`). A collision
   inside server tooling, observability or self-hosting is a real problem.
   (D24 in 03 is an unrelated decision.)
8. **No trademarked words** such as Ouija (Hasbro). Section 6 lists the
   names excluded up front.
9. **Identities are permanent.** The stem becomes Dart packages
   (`<app>_core`, `<app>_app` and others), the application id
   `ch.lkmc.<app>`, keystore entries and host artifact paths (04, section
   12.3). All of them are permanent once anything ships (D38).

---

## 2. Recommendation

**First choice: Hausgeist.** It is the only finalist that is collision-free
on every channel the screen covered (pub.dev, USPTO, both app stores, Docker
Hub, GitHub, web; GitHub shows only three repositories with 0 stars) and
also a native, unforced fit for both halves of the product: the spirit that
watches the house and keeps it running. It is German like Poltergeist (2:2
balance), friendly in register, already ASCII, and English speakers can say
it on sight. Its one cost is the "-geist" ending it shares with Poltergeist.

**Alternate 1: Voyant.** The most elegant pun (French seer and dashboard
warning light) and the closest in spirit to Planchette and Séance. Take it
only if you accept a crowded name: live US marks in software classes
(Voyant, Inc.'s business intelligence and financial planning software,
Voyant Photonics' lidar software), Voyant Tools, a taken `voyant` Docker Hub
namespace and several "Voyant" apps. None of them is server tooling, so
under rule 7 the risk is medium, not blocking.

**Alternate 2: Klabautermann.** The best pure Docker pun (a ship spirit
that arranges cargo, plugs leaks and knocks to warn), and no collision was
found anywhere. It costs length (13 letters) and spelling difficulty for
non-German speakers.

Only these three cover both watching and managing with a native meaning.
Before committing to any of them, run the checks in section 8.

---

## 3. How the candidates were screened

A candidate pool of 96 names in nine angles (section 7) was rated by gut
feel from 1 to 10. The rating weighs authenticity as spirit vocabulary, the
strength and breadth of the function pun (observability and containers is
best), fit with the loanword style, pronounceability, searchability and
collision risk. The pool's top 15, further pool names and four names from
outside the pool (Psychograph, Clairvoyant, Shewstone, Flaschengeist) then
went through the collision screen below. The pool ranked Voyant first (gut
9) and Hausgeist second (8); the screen reversed them because Voyant's name
is crowded.

| Check | Method | Coverage |
| --- | --- | --- |
| pub.dev | `GET https://pub.dev/api/packages/<pkg>` for `<name>`, `_core`, `_app`, `_server`, `_ui`, `_cli` (top four also `_agent`, `_sync`, `_docker`, `_metrics`, `_protocol`, `_desktop`, `_collector`) | 26 names. Control: `http` and `dartssh2` return 200 |
| Release-tool safety | `tool/release_version/lib/release_version.dart` (`_ownedPackageNames`, `_checkLocks`) re-pins lockfile entries by **exact** name. Only an exact match matters, but a shared prefix can still confuse people | All candidates |
| GitHub | GitHub repository search, `<name> in:name`, sorted by stars | 19 names |
| US trademarks | USPTO tmsearch API, live marks whose word mark contains the name | 24 names |
| EU, German and French trademarks | TMview API refused the connection; DPMA and EUIPO need JavaScript. Fell back to web search | **Gap**: no EU, DE or FR register query ran |
| Apple App Store | iTunes Search API (iOS and macOS, US store; top candidates also DE store) | 24 names |
| Google Play | Play search page, US | 12 names |
| Docker Hub | `hub.docker.com/v2/search/repositories` | 11 names |
| Web | General web search for products in devops, monitoring, Docker, SSH and server tooling | Finalists |
| Domains | None | **Gap**: no domain was checked |

---

## 4. Ranked shortlist

| Rank | Name | Language | Meaning | Function pun | Pronunciation | Conflict risk |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Hausgeist | German | House spirit; also the loyal helper who keeps a household running | Watches the house and does the chores: observability and management | HOWSS-gyste | Low |
| 2 | Voyant | French | Seer; also an indicator light | Sees what your servers do and lights up when one needs you | vwah-YAHN (FR), VOY-ent (EN) | Medium |
| 3 | Klabautermann | German, Frisian, Dutch folklore | Ship spirit that tends cargo, plugs leaks and knocks to warn | Tends the container fleet in Docker's nautical idiom | klah-BOW-ter-mahn | Low |
| 4 | Spiritoscope | English coinage, 1850s | Robert Hare's dial-and-pointer séance instrument | Gauges for CPU, RAM and disk; observability only | SPIR-it-oh-skohp | Low |
| 5 | Lutin | French | Household sprite that does chores at night | Cron, cleanup, restarts, pruning; observability weak | lue-TAN | Low |
| 6 | Pendule | French | Dowsing pendulum; clock | Finds hidden faults and keeps time for cron | pahn-DUEL | Low |
| 7 | Ghostlight | English | Lamp left burning on an empty stage | A light left on for unattended servers | GOHST-lite | Medium |
| 8 | Auspex | Latin | Roman augur who read bird flight | Reads the signs before trouble arrives | AW-specks | Medium |
| 9 | Corposant | Portuguese and Italian *corpo santo*; also French | St Elmo's fire, a sailors' omen | Status lights over your fleet | KOR-puh-zant | Low |
| 10 | Klopfgeist | German | Knocking spirit of séances | Knocks on every server: health checks, heartbeats | KLOPF-gyste | Low |
| 11 | Veilleur | French | Night watchman; *veille* also means standby and monitoring | Night watch over your servers | vay-YUR | Medium |
| 12 | Flaschengeist | German | Genie in a bottle | A spirit living in a container; nothing for observability | Not recorded | Low to medium |

---

## 5. Finalists

### 5.1 Hausgeist

- **Identifiers:** already ASCII: `hausgeist_core`, `hausgeist_app`,
  `ch.lkmc.hausgeist`.
- **Meaning:** German *Haus* (house) + *Geist* (spirit). Duden gives two
  senses: a spirit belonging to a house, and (humorous, dated) a
  long-serving household helper whom everyone values. The idiom *der gute
  Geist des Hauses* means the person who keeps everything running.
- **Pun:** Poltergeist moves your files; the Hausgeist keeps your house in
  order. It watches the house (logs, CPU, RAM, disk, cron) and does the
  chores (restart services, prune images, manage containers). It covers
  both halves of the product without stretching.
- **Conflicts:** pub.dev: none for any suffix checked. USPTO: no marks. App
  Store (US and DE, iOS and macOS), Google Play and Docker Hub: none.
  GitHub: three repositories with 0 stars:
  [tjchhajed/hausgeist](https://github.com/tjchhajed/hausgeist) (household
  chores AI app, 2026),
  [TrooperMaXX/HausGeist](https://github.com/TrooperMaXX/HausGeist) (Discord
  bot) and
  [magomi/alexa-hausgeist](https://github.com/magomi/alexa-hausgeist). The
  Home Assistant community card
  ["Domowoi the Hausgeist"](https://community.home-assistant.io/t/domowoi-the-hausgeist/950411)
  (Nov 2025, pre-release) uses the word as a descriptor; its product name is
  Domowoi. Two deleted German companies were named "Hausgeist Ltd"
  (commercial register).
- **Connotations:** German: positive and homely. English: a transparent
  "house ghost". French: no meaning. Nothing unfortunate found.
- **Costs:** the shared "-geist" ending with Poltergeist reads as family
  resemblance but invites mix-ups in speech. Package prefixes
  (`hausgeist_*`, `poltergeist_*`) stay distinct.
- **Tagline draft:** "The spirit that keeps your house in order."

### 5.2 Voyant

- **Identifiers:** already ASCII: `voyant_core`, `voyant_app`,
  `ch.lkmc.voyant`.
- **Meaning:** French, present participle of *voir*. Wiktionnaire lists
  these noun senses: a sighted person; a seer or fortune-teller who claims
  second sight (*voyante*); an indicator light meant to be highly visible;
  and, in navigation, the topmark of a beacon. As an adjective it means
  eye-catching or, pejoratively, gaudy.
- **Pun:** a clairvoyant who sees what your servers are doing, and the
  dashboard light that comes on when one needs you. The beacon sense adds a
  nautical echo for Docker. The management half is implied, not stated.
- **Conflicts:** pub.dev: no exact collision; `voyant_apis` (Flutter SDK
  for an NSFW-detection API) shares the prefix. USPTO, live: VOYANT, Voyant,
  Inc. (financial planning and business intelligence software, Class 42
  reg. 7831875; Class 9 application 98606253 for "software ... combining
  information from various databases and presenting it in an
  easy-to-understand user interface", suspended); VOYANT, Voyant Photonics
  (lidar hardware and software, Class 9 reg. 8395989); VOYANT, Voyant
  Communications (VoIP, Class 38). Voyant Tools, a well-known text-analysis
  suite ([voyanttools/Voyant](https://github.com/voyanttools/Voyant),
  [VoyantServer](https://github.com/voyanttools/VoyantServer)). Apps: Voyant
  Presence and Voyant: Arrival Intelligence (iOS), Voyant: Car Expense
  Tracker (Android), and the similar-sounding Voyent Alert! (emergency
  alerts). Docker Hub: the `voyant` namespace is taken (Spring Boot Admin
  images, about 357k pulls).
  [Voyance](https://www.capterra.com/p/177668/Voyance/) is a
  network-monitoring SaaS with an adjacent word. No server or Docker
  tool is named Voyant.
- **Connotations:** French: *voyance* also evokes premium-rate psychic
  hotlines, and the adjective can mean "garish". English: a rare word; some
  people may hear "voyeur". German: no meaning.
- **Costs:** a crowded name (above); English and French speakers will not
  agree on one pronunciation; the suite becomes 3 French to 1 German.
- **Tagline draft:** "It sees what your servers are doing, and lights up
  when they need you."

### 5.3 Klabautermann

- **Identifiers:** `klabautermann_core`, `klabautermann_app`.
- **Meaning:** a ship spirit from North Sea folklore (German, Frisian,
  Dutch, attested since at least the 1770s). It pumps water from the hold,
  arranges cargo and ballast, hammers at leaks and knocks on the hull to
  warn the crew. The name probably comes from *Kalfater* (caulker); the
  Grimms linked it to *klabastern* (to knock). In the lore, seeing it means
  the ship is doomed.
- **Pun:** Docker's vocabulary is nautical (containers, whale, Kubernetes
  "helmsman"). A spirit that arranges the cargo (containers), plugs leaks
  (restarts) and knocks to warn you (alerts) covers both halves of the
  product.
- **Conflicts:** pub.dev, USPTO, App Store (US and DE), Google Play, Docker
  Hub: none. GitHub: nine repositories with 0 stars (for example
  [joelgsponer/klabautermann](https://github.com/joelgsponer/klabautermann),
  a personal assistant;
  [devarminas/klabautermann](https://github.com/devarminas/klabautermann),
  Go, Sept 2026, no description). Web: no software product found.
- **Connotations:** German: a friendly kobold (Pumuckl is said to descend
  from it), with the doom-omen footnote. English: unknown to most, though
  One Piece fans know the Going Merry's Klabautermann. French: no meaning.
- **Costs:** 13 letters is long for a window title, launcher label or
  Android home screen; the double "nn" will be misspelled. It is a helper
  spirit more than a séance term.
- **Tagline draft:** "The ship's spirit that keeps your containers afloat."

### 5.4 Spiritoscope

- **Meaning:** Robert Hare's 1850s séance test apparatus (*Experimental
  Investigation of the Spirit Manifestations*, 1855): a pointer moved over a
  lettered dial that the medium could not see. A sibling of the planchette
  and an ancestor of dial-plate talking boards.
- **Pun:** a dial and pointer that read out hidden signals, such as gauges
  for CPU, RAM and disk. "-scope" says observation. No container or
  management angle.
- **Conflicts:** pub.dev, USPTO, GitHub, App Store, Google Play, Docker Hub:
  none. The web finds only ghost-hunting toy apps with other names.
- **Costs:** five syllables; names only half the product; an English
  coinage, not a loanword (German: *Spiritoskop*). It has the strongest
  spiritualist pedigree after Planchette.

### 5.5 Lutin

- **Meaning:** French household sprite that does chores at night and plays
  tricks; also the French word for Santa's elves.
- **Pun:** night chores: cron, cleanup, restarts, image pruning.
- **Conflicts:** pub.dev and USPTO (no live marks): none. GitHub:
  [Halloweedev/lutin](https://github.com/Halloweedev/lutin) (Swift, 13
  stars). Google Play: LutinRouge family apps; the Routineday habit tracker
  uses the Android ID `cc.underthehood.lutin.app`. Docker Hub: unrelated
  user names only.
- **Costs:** weak observability pun; more elf than ghost. English speakers
  will say LOO-tin, close to "lutein". The archaic French verb *lutiner*
  means to tease flirtatiously (mild).

### 5.6 Pendule

- **Meaning:** French *le pendule* is a dowsing pendulum; *la pendule* is a
  clock. German also uses *Pendule* for a mantel clock.
- **Pun:** a divination tool that finds hidden faults, and a clock for
  scheduled jobs.
- **Conflicts:** pub.dev, USPTO, Docker Hub: none. GitHub: only clock and
  physics repositories (for example Pendule-SNCF, 11 stars). Stores: clock
  and hangman games (*Le Pendu*).
- **Costs:** names cron and diagnostics, not containers or metrics: too
  narrow for the whole product. It shares a root with French *pendu*
  (hanged man), though the word itself carries no such meaning.

### 5.7 Ghostlight

- **Meaning:** the single lamp left burning on an empty stage, for safety
  and, by superstition, for the theatre's ghosts.
- **Pun:** a light left on for your unattended servers; status lights.
- **Conflicts:** pub.dev: none. **Internal clash:** the suite already ships
  the shared packages `ghost_ui`, `ghost_desktop` and `ghost_marks`, so
  `ghostlight_core` would look like part of that family. USPTO: live
  GHOSTLIGHT marks for live entertainment (Poet Productions), film
  production, and Ghostlight Records (Class 9 recordings, Class 38
  streaming); no software marks. Apps: Ghostlight ETC (education),
  Ghostlight Live, GhostLight (game). GitHub: small repositories, including
  a data-secrets scanner
  ([AyushAggarwal1/ghostlight](https://github.com/AyushAggarwal1/ghostlight),
  also on Docker Hub) and an "MBTA Feed Integrity Monitor".
- **Costs:** the internal clash; an English compound, not a loanword.

### 5.8 Auspex

- **Meaning:** Latin *avis* + *specere*, a Roman augur who read bird flight;
  the root of "auspices". Also the handheld scanner in Warhammer 40k.
- **Pun:** reads the signs before trouble arrives (predictive alerts).
- **Conflicts:** pub.dev: none. USPTO: live AUSPEX filings in Class 42 from
  2025 to 2026 (Raven AI Intelligence SaaS, a conflict-of-interest SaaS,
  Auspex Digital software development) plus Class 35 and sunglasses. Docker
  Hub: [auspexeu/openvpn-status](https://hub.docker.com/r/auspexeu/openvpn-status),
  an OpenVPN server connection monitor with about 89k pulls (adjacent).
  Auspex Systems was a NAS server vendor (defunct 2003). Apps: Auspex Pro
  (traffic, Gridsmart), Auspex: Stock Analysis. GitHub: mpenet/auspex
  (Clojure, 44 stars), BBN-Q/Auspex (lab instruments).
- **Costs:** Roman augury, not spiritualism; Latin breaks the French and
  German pattern; recent software filings.

### 5.9 Corposant

- **Meaning:** from Portuguese and Italian *corpo santo* (holy body): St
  Elmo's fire on a ship's mast, a sailors' omen. The word also exists in
  French.
- **Pun:** status lights glowing over your fleet, in Docker's nautical
  idiom.
- **Conflicts:** none on pub.dev, USPTO, stores or web. GitHub: three
  trivial repositories. Docker Hub: one image with 41 pulls.
- **Costs:** obscure in every language; English speakers hear "corpse".

### 5.10 Klopfgeist

- **Meaning:** German "knocking spirit", the rapping spirit of séances.
- **Pun:** knocks on every server: health checks, pings, heartbeats.
- **Conflicts:** none on pub.dev, USPTO, stores or Docker Hub. On GitHub,
  the user name "Klopfgeist" hosts small weather apps.
- **Costs:** almost a synonym of Poltergeist, so the two products would be
  easy to confuse; the "pf" is hard for English speakers.

### 5.11 Veilleur

- **Meaning:** French night watchman. The *veillée* is the wake kept over
  the dead. The *veille* family also covers standby (*mise en veille*) and
  technology monitoring (*veille technologique*).
- **Pun:** a night watch over your servers.
- **Conflicts:** USPTO: only Shiseido's VEILLEUR DE NUIT perfume. GitHub,
  adjacent but tiny:
  [krezzoid/veilleur-ai](https://github.com/krezzoid/veilleur-ai)
  ("always-on on-call agent for small teams without a dedicated SRE", Sept
  2026, 1 star) and [s2j1h/veilleur](https://github.com/s2j1h/veilleur)
  ("watchdog-like webapp", 2011).
- **Costs:** hard for English and German speakers to pronounce; the
  on-call agent repository sits in the same category.

### 5.12 Flaschengeist (added during the screen)

- **Meaning:** German "bottle spirit", the genie in a bottle that serves
  whoever opens it (compare Grimm's *Der Geist im Glas*).
- **Pun:** a spirit living in a container. A very good Docker pun, but
  nothing for observability.
- **Conflicts:** pub.dev, USPTO (no live marks), Docker Hub: none.
  Flaschengeist is an Australian spirits and non-alcoholic drinks brand.
  German App Store searches surface Akinator (a genie game).
- **Costs:** in German, *Geist* also means distilled spirit
  (*Himbeergeist*), so the name reads as liquor; hard for English speakers
  to pronounce.

---

## 6. Notable rejected candidates

"Vetting" rows were rejected at the shortlist step that ran the collision
screen. "Pool" rows were excluded before it, on general knowledge rather
than a search.

| Name | Stage | Reason |
| --- | --- | --- |
| Revenant | Vetting | Live USPTO Class 42 REVENANT (NetCentrics, reg. 7672374) for platforms that deploy, configure, maintain and manage cyber-security systems: squarely the domain. [0xTriboulet/Revenant](https://github.com/0xTriboulet/Revenant) (388 stars) is a Havoc C2 implant agent, so a server-side component would share a name with known offensive tooling. Corpse lore breaks the friendly register |
| Scry | Vetting | [Scry: Remote Desktop](https://apps.apple.com/app/id6768108037) (Bravely Studios, June 2026) controls Mac, Windows or Linux machines from iPhone and iPad: same remote-access category. Live USPTO SCRY Class 42 SaaS mark |
| Daimon | Vetting | Cannot be searched apart from "daemon". DAIMON Class 9 and 42 applications (Prospinity, AI advice app on iOS and Android). Many 2026 AI-agent repositories named daimon |
| Familiar | Vetting | Common adjective, hard to search. 37 live USPTO FAMILIAR marks, including Class 9 social-networking software. Witchcraft, not spiritualism |
| Lares | Vetting | Lares is an offensive-security (red team) consultancy with live USPTO Class 35, 41 and 42 marks. Ksenia Security's "lares" alarm-panel apps are adjacent monitoring |
| Wisp | Vetting | pub.dev package `wisp` exists (0.0.1-dev, Apr 2026). WISP is the networking acronym for a wireless ISP. Crowded apps (Wisp VPN and others) and 27 live US marks |
| Psychograph | Vetting (added) | Reads as "psycho". Search is dominated by marketing "psychographics". USPTO Class 35 application (market analysis) |
| Stonetape | Vetting | Logs-only pun. Names a specific 1972 horror play. A tiny "stonetape" LLM-testing repository exists |
| Guéridon (`gueridon`) | Vetting | Indirect pun (table-turning table). [spm1001/gueridon](https://github.com/spm1001/gueridon) is a mobile web UI for Claude Code (developer tooling, tiny) |
| Clairvoyant | Vetting (added) | Live USPTO CLAIRVOYANT Class 9 and 42 applications by D&G Analytics for threat-detection and malware-analysis software (adjacent security). Plain English word |
| Shewstone | Vetting (added) | John Dee's scrying stone. Clean, but archaic English, ambiguous pronunciation ("show" or "shoe") and not a loanword |
| Voyance | Vetting | Network-monitoring analytics SaaS of the same name (Capterra) |
| Vigil | Vetting | Self-hosted Rust status-page monitor (valeriansaliou/vigil) |
| Geisterseher, Spökenkieker, Heinzelmännchen | Vetting | Too long and obscure for an app label. Umlauts need ASCII forms (`spoekenkieker`, `heinzelmaennchen`) |
| Schutzgeist | Vetting | *Schutz* (protection) makes it read as a security product |
| Haruspex, Necromancer, Exorcist, Lazarus, Ossuary and similar | Vetting | Gore, horror or hostile associations (Lazarus Group) break the friendly register |
| Ouija | Pool | Hasbro trademark |
| Oracle, Medium | Pool | Oracle Corporation; Medium.com |
| Sentinel, Teleport | Pool | Same domain: Microsoft Sentinel (SIEM) and Redis Sentinel; the Teleport SSH and infrastructure access platform |
| Remote Viewer | Pool | virt-viewer's SPICE/VNC client |
| Ghost, Phantom, Spectre/Specter | Pool | Ghost CMS; Phantom wallet, PhantomJS; Spectre CPU vulnerability |
| Esprit, Sprite | Pool | Fashion brand; Coca-Cola |
| Ovilus, Mel Meter, REM-Pod, K-II | Pool | Ghost-hunting device brands |
| Anubis | Pool | Widely deployed self-hosted anti-scraper proxy |
| Haunt, Summon | Pool | The suite name; Séance's tagline |
| Nightwatch, Lantern, Echo | Pool | Nightwatch.js; Lantern app; Amazon Echo |

---

## 7. Long-list by angle

The other pool candidates, one line each. None of them went through the
collision screen; the notes are recalled from general knowledge, not
searched. "Gut" is the pool rating from section 3.

### (a) Seeing the hidden or distant

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Second Sight | English | Clairvoyance, seeing what others cannot | A second view onto every server | Two words; Second Sight Medical (retinal implants) | 5 |
| Telesthesia | Greek *tele* + *aisthesis*; F. W. H. Myers' term | Perception at a distance | Remote monitoring, exactly | Unknown to most, medical-sounding | 4 |
| Augure | French | Augur; also an omen (*de bon augure*) | Alerts as omens | Weak in English; Augur (crypto prediction market) | 4 |
| Psychometry | Greek, "soul measuring" | Reading an object's history by touching it | A server's past from its logs; also "metric" | Collides with psychometric testing in search | 4 |
| Hellseher | German, "clear seer" | Clairvoyant | Sees clearly into servers | English speakers read "Hell" | 2 |
| Seer | English | One who sees the future | Watches servers | Seerr, Overseerr and Jellyseerr are popular self-hosted apps | 3 |

### (b) Séance apparatus and phenomena

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Rapport | French, "report"; mesmerism term | *En rapport*: the link between medium and subject | Reports, plus a live link to each server | Spiritualist sense unknown to most English speakers | 6 |
| Cabinet | English, French | Spirit cabinet for materializations (Davenport brothers) | A box where things materialize: containers | Docker-only pun; generic word; .cab files | 5 |
| Apparition | French, English, from Latin *apparere* | A ghost appearing | Makes hidden server state appear | Long, generic | 5 |
| Slate | English | Slate writing (Henry Slade) | Log lines appearing on the slate | Common word; Slate magazine, Slate API docs tool | 5 |
| Ectoplasm | Greek; coined by Charles Richet, 1894 | Substance exuded by a medium | Containers and images materializing | Slimy image; Ecto (Elixir) in dev search | 4 |
| Manifest | English | Spirits manifest | Docker and Kubernetes manifests | Generic, unsearchable | 4 |
| Apport | French *apporter*, "to bring" | Object a spirit materializes from elsewhere | Images pulled from a registry appear on the host | Ubuntu's Apport crash reporter, same domain | 3 |
| Typtologie | French, Greek, "study of knocks" | Spirit communication by counted raps | Health checks and pings as knocks | Obscure, hard to say | 3 |
| Spirit Trumpet | English | Cone through which spirit voices spoke | Logs speak through it | Two words, weak | 3 |

### (c) Ghost-hunting instruments and theories

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Kirlian | Russian surname (Semyon Kirlian, 1939) | Photography said to show an aura | Makes invisible energy visible: CPU heat, load graphs | A person's name; pseudoscience association | 5 |
| Spectral | English, from *spectre* | Ghostly; of a spectrum | Spectrum analysis of metrics | Stoplight Spectral (API linter) in dev tooling | 4 |
| Coldspot | English | Ghost hunters look for cold spots | Finds hot and idle spots | Inverted pun reads oddly | 4 |
| Spirit Level | English | Bubble level | Measures disk, RAM and load levels | Two words; book of the same name | 4 |
| Spirit Box | English | Radio sweep device for ghost voices | Scans servers; box as container | Spiritbox (band); device brands nearby | 3 |
| Ghost Box | English | Same device class | Box as container | Ghost Box Records (label) | 3 |
| Geophone | Greek | Vibration sensor used by ghost hunters | Detects load spikes | No spirit meaning on its own | 3 |

### (d) Keeping watch

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Veillée | French | Vigil, wake, an evening watch | Night watch over servers | Accent; sounds like "olé" | 5 |
| Veilleuse | French | Night light, pilot light; *en veilleuse* means on standby | A small light always on | Feminine diminutive reads soft | 5 |
| Wake | English | Watch kept over the dead | Watches; also wake-on-LAN | Generic, morbid | 4 |
| Lanterne | French | Lantern; *lanterne magique* | Lights the way | Lantern (circumvention app) in English search | 4 |
| Grim | English, church grim | Spectral dog that guards a churchyard | Watchdog | Reads negatively | 4 |
| Lykewake | Old English *lic* (corpse) + wake | Night watch over a body | Overnight watch | Morbid | 3 |

### (e) House and ship spirits

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Tomte | Swedish | Farmstead spirit that tends the farm at night | Tends your server farm | Reads as Christmas gnome | 5 |
| Kobold | German | Household and mine spirit (gave its name to cobalt) | Tends the house | KoboldAI and koboldcpp are popular in self-hosting | 4 |
| Wichtel | German | Small house spirit; *Wichteln* is Secret Santa | Night work | Hard to pronounce; Christmas association | 4 |
| Domovoi | Russian, Slavic | House spirit guarding the household | Guards the house | Domovoi Python framework; breaks the French and German pattern | 4 |
| Farfadet | French (Poitou) | Benevolent household sprite | Chores | Cute, obscure | 4 |
| Hob | English | Hearth spirit (hobgoblin) | Keeps the hearth | Kitchen hob | 4 |
| Brownie | Scottish | House spirit that does chores | Chores | Reads as cake | 2 |

### (f) Spirits that return or are summoned

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Psychopomp | Greek *psychopompos*, "guide of souls" | Escorts souls between worlds | Guides processes through their lifecycle | Fun word, obscure | 5 |
| Banshee | Irish *bean sí* | Spirit whose wail foretells a death | Alerting | Herald of death; Banshee media player (defunct) | 5 |
| Wiedergänger | German, "again-goer" | Revenant | Restarts | Hard; ASCII `wiedergaenger` | 4 |
| Conjure | English, French *conjurer* | Summon a spirit | `docker run` | Overlaps Séance's "summon" tagline | 4 |
| Summoner | English | One who summons | Starts containers | Too close to Séance's tagline | 3 |

### (g) Containers of the dead and relics

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Reliquary | Latin *reliquiae* | Ornate box holding relics | Containers holding images | Docker-only pun | 5 |
| Djinn | Arabic *jinn* | Spirit in a lamp or bottle that serves when summoned | A spirit in a container that does what you ask | Not Western spiritualism; several libraries | 4 |
| Witch bottle | English | Bottle buried at a house to trap harmful spirits | A sealed container protecting the house | Two words | 3 |
| Cenotaph | Greek, "empty tomb" | Monument without a body | Stopped containers | Morbid | 3 |
| Catacomb | Latin, Italian | Underground burial network | Container network | Morbid; game titles | 3 |
| Crypt | Greek | Burial vault | Containers | Reads as crypto or encryption | 2 |

### (h) Further French and German terms

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Zeitgeist | German, "spirit of the time" | Spirit of an age | Time series: your servers over time | Generic; GNOME Zeitgeist (activity logging), Google Zeitgeist | 5 |
| Doppelgänger | German, "double-goer" | Spectral double of a living person | A live mirror of each server's state | Long; ASCII `doppelgaenger` | 5 |
| Geisterstunde | German, "ghost hour" | The witching hour, midnight | Midnight cron jobs | Long, cron-only | 4 |
| Feu follet | French, "mad fire" | Will-o'-the-wisp | A light over your servers | Two words | 4 |
| Fantôme | French | Ghost | None specific | No function pun | 3 |
| Spuk | German | Haunting, spook | None specific | No function pun | 3 |
| Irrlicht | German | Will-o'-the-wisp | Light | Irrlicht 3D engine | 3 |

### (i) Other angles

| Name | Origin | Meaning | Function pun | Notes | Gut |
| --- | --- | --- | --- | --- | --- |
| Daimonion | Greek | Socrates' inner voice, which only warned him away from mistakes | An alerting voice that speaks only when something is wrong | Obscure | 5 |
| Pepper's Ghost | English, J. H. Pepper, 1862 | Stage illusion: angled glass shows a figure hidden backstage | The "single pane of glass" showing what is hidden backstage | Awkward form; "Pepper" alone loses the ghost | 5 |
| Grimoire | French | Book of spells | Runbooks, saved commands, cron scripts | GrimoireLab (CHAOSS software analytics), adjacent | 5 |
| Omen | English | A sign of what is coming | Predictive alerts (disk full in three days) | HP OMEN computer brand; horror film | 5 |
| Sitter | English, séance usage | The client who sits with the medium | A server-sitter that sits up with your machines | Generic, unsearchable | 5 |
| Fantasmagorie | French (Robertson's Paris shows, 1790s) | Magic-lantern ghost projections | Live projections of hidden state: dashboards | Long | 4 |
| Harbinger | English | Forerunner, herald | Early warnings | Long, generic | 4 |
| Akasha | Sanskrit, Theosophy | Akashic records, a cosmic log of all events | The log of everything | Akash Network (decentralized cloud), adjacent | 4 |
| Charon | Greek | Ferryman of the dead | Ferries containers across | Not spiritualism; moon of Pluto; several tools | 4 |
| Hauntd | Suite name + Unix daemon suffix | A haunting daemon | `sshd`, `crond`, `hauntd` | Confusable with the suite itself | 4 |
| Tommyknocker | Cornish mine lore | Mine spirits that knock before a cave-in | Warns before a collapse | Stephen King novel; slang | 3 |
| Flying Dutchman | English, Dutch | Ghost ship that can never make port | Containers that run forever | Doom connotation; two words | 3 |
| Vigie | French | Ship's lookout or crow's nest | Watching; nautical | Near miss: no spirit meaning | 3 |

---

## 8. Checks still required before committing

The screen is a snapshot from 2026-10-10. Before the owner fixes the name
(D38), run these for the chosen name:

1. **Trademark registers.** Search EUIPO eSearch (EU), DPMAregister
   (Germany) and INPI (France) in Nice classes 9 and 42. None of them was
   queried: TMview refused the connection, DPMA and EUIPO need JavaScript,
   and the fallback was a web search. The USPTO search covered live US
   marks only.
2. **Domains.** No domain was checked for any candidate.
3. **App-store names at publication time.** The App Store search covered
   the US store (top candidates also DE) and Google Play the US only. Names
   can be claimed at any time, so repeat both searches, in every region the
   app will be listed in, immediately before the first release.
4. **Every planned package name.** The pub.dev queries covered the suffixes
   in section 3. 04, section 12.3 also plans `<app>_host` and the workspace
   `_<app>_workspace`; `_host` was not queried for any candidate, and
   `_docker` only for the top four. Query each planned name on pub.dev and
   confirm that no lockfile in the repository has an entry with that name
   (rule 6).
5. **Refresh the screen.** Rerun the pub.dev, USPTO, GitHub and Docker Hub
   checks on the decision date, then record `<App>` and `<app>` in 04,
   section 12.3.
