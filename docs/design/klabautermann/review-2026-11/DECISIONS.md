- Q1 reboot wait: keep wait card (progress only) after leaving admin mode
- Q2 sign-out: match Poltergeist (forget token/keys/enrollment, remove sync-only servers + cached profiles/history, keep local servers + pins, confirm if removed servers have open connections)
- Q3 badge: unseen raised alerts, cleared on opening that server's alerts, only while notifications on; macOS+iOS only, no new dep
- Q4 UI-06: "Copy to..." button opens confirmation sheet (host+folder, Copy / Change folder / Cancel)
- Q5 P4-21: app-internal clipboard; Cut=move any source (same host rename, cross-host copy then delete after verified copy); Undo: rename, move, local trash Put Back, AND undo copy = delete copied files with confirmation; remote deletes not undoable
- Q6 F7: share editor registry, Seance gains per-extension; current editor = default; settings stay readable
- Q7 A2: quit silently + restore (setting to turn off -> classic prompt); journal until saved/discarded, never synced, owner-only perms, deleted on Don't Save/close-without-saving
- Q8 A3: Save As dir = file's folder; untitled -> last folder for that extension, then last Save As folder, then system default
- Q9 B37: bundle Unicode CaseFolding (full) for plain-text search with Unicode License v3 notice; regex keeps simple folding
- Q10 I3: hard-linked files: backup copy, write in place, remove backup
- Older decisions B29/B35/A9/F2/I4/B10/AppImage pin/pkey recovery: already resolved on main

- F5 link queues: ONE SHARED QUEUE in seance_core; Seance adopts Poltergeist review/discard/cancel. (user, 2026-11-16)
- Planchette app lock: ADD optional lock (off by default), shared code, local_auth, Android FragmentActivity, iOS Face ID string. (user, 2026-11-16)

- Klab review 2026-11-24 (user): quit-while-locked stays (UIB-4 declined); BUILD anacron (JOB-04) and sockets (SVC-10) screens; app RESTARTS the engine after it dies and says so.
- Klab review 2026-11-25 (user): ARC-15 MOVE Klabautermann's ssh_config resolver into seance_core and have Séance's importer use it (Séance and Poltergeist then import with full ssh -G semantics).
