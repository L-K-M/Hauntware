# Source history

Full, unsquashed imports retain original commits under `planchette/`,
`seance/` and `poltergeist/`. The import baseline matches these reviewed mains:

| Project | Source main |
| --- | --- |
| Planchette | `754148bc2ef4a004bb95b9f1348bd44f11350700` |
| Séance | `75b1e84bf231d149d64c295430a9dda9dc7f4ffb` |
| Poltergeist | `41eed4e0cb41e5015c8fe88f95e16cb50e011a22` |

`source-refs.json` records captured local/origin branches and release tags.
History-only merge parents retain rejected, superseded and experimental
commits without adopting their trees. Ancestry alone does not mean a feature
ships. Supported missing Planchette intents were reimplemented in #133;
Séance #172/#44/#45 and Poltergeist #252 were reviewed and merged first.

The rejected age-only temporary-file sweep and obsolete signing workflow
remain historical. Wrap-off still needs a horizontal viewport; existing
defaults remain. Frozen M0 measurements retain their original revisions.

## Reading old paths

Pre-import commits use their original repository-root paths:

```bash
git show 0a695971a411a6a754593e7c2598038039440c2f:packages/seance_core/pubspec.yaml
```

Integration commits use the new project prefixes. Original repositories and
their release artifacts remain intact; no release tags were published here.

## Verifying and recovering metadata

Use a full-history checkout:

```bash
python3 scripts/check-history.py
```

For an annotated tag, join its `tagBase64` chunks and base64-decode them.
`git hash-object -t tag --stdin` must equal its recorded `object` hash.
This preserves the exact tagger, timestamp, message and target without
creating colliding release tags. Recreating tag refs is an explicit action.
