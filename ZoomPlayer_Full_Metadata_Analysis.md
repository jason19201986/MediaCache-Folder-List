# Zoom Player MediaCache — full metadata analysis (v6, consolidated)

**Binary:** `zplayer.exe`, 10,178,560 bytes, MD5 `97b19d1d56185b0c7262f84b1a49b597`, ImageBase `0x400000`.
All addresses are runtime VAs. Labels: **code-confirmed / strongly supported / inferred / unresolved**.
Tooling: read-only byte scans + `[tool] extern` Ghidra headless decompilation of a *copy* project
(`C:\Users\jason\AppData\Local\Temp\ghidra_full_copy\ZoomPlayerAnalysis`; the user's original project
was never saved).

This pass consolidates v2–v5, retracts several earlier readings, and closes the two remaining code
questions (the `modified` serializer path and the icon dispatcher).

---

## 1. `modified` — final answer (supersedes the "Unix-seconds" line of v2–v4)

### 1.1 The runtime helpers (code-confirmed, decompiled)

| VA | Identity |
| --- | --- |
| `0x8CD044` | `FindFirstFile*` → dir check → `FileTimeToLocalFileTime(ftLastWriteTime)` → `FileTimeToDosDateTime` → returns DWORD DOS last-write time; `0xFFFFFFFF` on failure |
| `0x8CD150` | same, canonical form (pure: FindFirstFile → LocalFileTime → DosDateTime, no rounding) |
| `0x8CD27C` | same family but on **ftCreationTime** (adds `SystemTimeToTzSpecificLocalTime`/`SystemTimeToFileTime`), returns DOS creation time |
| `0x8CD3E8` | `GetFileAttributesExA/W` variant of the DOS-time reader (returns two dwords from the WIN32_FILE_ATTRIBUTE_DATA record; `0xFFFFFFFF` pair on failure or directory) |

(deliverable `raw/ghidra_decomp_tier2.txt` §FUN_008cd3e8; earlier family dump `raw/dos_helpers_family.txt`)

### 1.2 The writer (code-confirmed, decompiled)

`FNA_0x005ED890` — the media-item update function — for each path:

```
puStackY_5c := FUN_008CD27C(path)        ; DOS creation time
puStackY_64 := FUN_008CD3E8(path)        ; DOS pair (GetFileAttributesEx)
if type(field +0x70) == 8:
    +0x78 := FUN_008CD150(path)          ; DOS last-write time
if both = 0xFFFFFFFF: pair := 0
IntToHex(FUN_008CD27C(...), 8) -> string concat block -> "modified=<8 hex digits>"
```

`FUN_0040D87C` / `FUN_0040D8A4` are `SysUtils.IntToHex(value, digits)` (base `0x10` pushed in `ECX`).
For a loaded record, `FUN_005E9D20` result dwords `[4]/[5]` go straight into **item+0x88 / item+0x8C**
(preserve-on-refresh), and the serializer (`0x5E8888` family) writes `file+0x34 <- item+0x8C`,
`MediaCache +0x30 <- item+0x88` — so the *corpus* values are simply the stored DOS-packed dwords.

### 1.3 Empirical closure

The stable empirical rule (validated on every corpus entry): `modified` decodes chronologically as a
**scan wave** (1BR 17:53:50 → Minecraft 17:54:06 → Sonic2 17:54:14, alphabetical), equal to the
**directory's NTFS last-write time in DOS-packed form, rounded up to an even second** (DOS-time
granularity); a fresh scan re-stamps, a refresh preserves verbatim (loader `0x5EA315` parses
`modified` into record+0x34 from the cache line; the copy block `0x5F0C36` then re-copies it).

### 1.4 Retraction of the Unix-seconds theory

The v2/v3/v4 claim that `record+0x34` holds **32-bit Unix seconds** (v2: "1565626055 = 2019-08-12")
is **retracted**. `0x5D518EB__` values are DOS-packed date-times decoding to **Oct 17–19, 2026** —
the actual library-build window; the "Aug-2019 import" was an artifact of misreading DOS dwords as
Unix seconds. There is no timestamp *conversion* anywhere in the chain (v4 §8.1 resolved negative);
`0x5E8510` (list resolver), `0x5E8634` (path resolver), `0x8CDC28` (case-normalizing comparator)
were confirmed to contain no time logic, and none is needed.

**Sentinels** (strongly supported): `+0x48`-family fails mark tech-scan failure
(`0xFFFFF830` @0x5ED392) and schedule-failure (`0xFFFFF82F` @0x5EDEE7); on these gates the update
short-circuits and fields keep prior values — the code-level explanation for
"modified preserved but list re-escalated" observed Oct-19.

---

## 2. `mediaicons` — final answer (supersedes v2–v4 §2)

### 2.1 Key table + serializer (code-confirmed)

Key-name table `0x98B680–0x98B704` (one string constant per cache key):
`mediaicons` cell `0x98B6B8`, `modified` cell `0x98B6CC`, plus `width/height/mediacount/…`.
Label-pointer cells: `mediaicons → 0x9986C8`, `modified → 0x998A78`.

Writer (serializer family 0x5E8888+): line = `label Dereferenced via 0x9986C8 + stringify(record+0x30)`
via the vtable+0x38 line-writer; the `0x5E8888` entry is a generic **key=value add-or-replace**
(cache-line dedupe) helper — v3's "icon scrubber" label retracted (v4 §2.4, retained).

Loaders (CSV split): `0x8A2EF9`, `0x8A5E00`, `0x8A71A5` each take the `mediaicons` line,
`call 0x958bf4(value, record, ',', …)` splitting the comma-separated IDs into the record's list;
`0x8C1616` is a table-reset pass, not a parser.

### 2.2 The icon dispatcher — entry verified, full mapping closed (v4 §8.2 resolved)

- **Entry chain (code-confirmed):** `FUN_008A9F90` (wrapper: on `arg1==1` creates the icon-cache
  object — class ptr `0x8A2108` — into global `0x98C350`; otherwise worker-thread path:
  synchronized wait (`0x4E5010`, 1000 ms) → `FUN_00836644(...,5000)` → **`FUN_008AA010(0)`** → `0x836C60`).
- `FUN_008AA010` (`0x8AA010–0x8B4F5F`) contains the whole resolver: a token loop at `0x8B3686`
  (`StrToInt` `0x40D910` for numeric tokens; `0x4058E4` string-compare for name tokens), the full
  compare-ladder around `0x8B3800–0x8B49xx`, then the guard
  `cmp edi,-1 / jle … ; cmp edi,0xAE ; jge …` and the consumer anchor `[0x8EF3A8]`.
- **Full string→ID mapping harvested** (176 raw case rows → `raw/icon_dispatcher_ladder.txt`);
  highlights:

  | class | examples |
  | --- | --- |
  | media types | `textfile`=60, `picture`=1, `audio`=2, `video`=3, `dvd`=4, `archive`=7, `folder`=8 |
  | overlays | `seenoverlay`=72, `audiooverlay`=77, `videooverlay`=78, `subtitleoverlay`=79, `thumboverlay`=81 |
  | resolutions | `res480i`=90, `res480p`=91, `res576i`=92, `res720p`=94, `res1080p`=95, `res1080i`=96, `res4kuhd`=97, `res8kuhd`=98, `res540p`=140 |
  | formats | `formatmkv`=101, `formatmp4`=104, `formatwmv`=105, `formatwebm`=106, … |
  | codecs | `codech264`=116, `codech265`=117, `codech266`=169, `codecav1`=149, `codecaac`=118, `codecdd`=120, `codecdts_x`=150, `codecddatmos`=151, … |
  | ratings | `rating_tv_y`=153 … `rating_nc17`=163 |

  (earlier exact-range claims "0x8B3F00–0x8B48F0 = dispatcher" retracted per v4 §2.3; the chain is
  inline inside `FUN_008AA010`.)

### 2.3 Producer chain closure (v4 §8.3 resolved)

item `+0x88` (mediaicons source field) is filled by the scanner/tech pass (stores at
`0x5EDE1A`, `0x5EE7A1`, `0x5EEF2D`, `0x5EFC56`, `0x5EFCDA`, `0x5F0415` — all inside the media tier),
copied to `record+0x30` by ctor `0x5ED068` (param `+0x2C`) and copy-block `0x5F0C36`
(`record+0x30 ← [item+0x88]`, same class `0x5e8254` on both paths), serialized through the
`0x9986C8` label cell, and re-parsed by the CSV-split loaders. The dispatcher consumes the same
name tokens (`mov eax,[ebp-0x2c]; mov edx,<name>; call 0x4058E4; mov edi,<id>`) — one coherent loop:
tech pass → item field → record → CSV → icon IDs.

---

## 3. The Oct-19 23:12 wave-writer identity — still unresolved

Read-only hunts extended in v4 (Desktop depth-0/1, AppData Local Temp depth-2, Roaming depth-3,
Recent `.lnk`) found only the saved Fix3 script and the earlier-day report; the quoted
`..._231207.txt` report is absent everywhere traversed. The wave executor (425 files, 25 s,
four-field-only writes with `modified` preserved) remains unidentified. Not pursued further this
pass (no destructive search; no Prefetch inspection).

## 4. Claims retracted / corrected this pass (against earlier sessions)

| # | claim | status |
| --- | --- | --- |
| 1 | `modified` = 32-bit Unix seconds ("Aug-2019 corroboration") | **RETRACTED** — DOS-packed date-times (§1.4) |
| 2 | mediaicons dispatcher = "0x8B3F00–0x8B48F0" as a function range | **REFINED** — inline chain inside `FUN_008AA010` (§2.2) |
| 3 | `0x5E8888` = icon-family dedupe scrubber | retained v4 correction: generic key=value add-or-replace |
| 4 | v2/v3 "TDateTime/ISO8601" helper labels (`0x5E8510`, `0x5E8634`, `0x8CDC28`) | retained v4 retractions; helpers are non-time utilities |

## 5. Deliverables (this pass — `investigation_full/`)

- `ZoomPlayer_Full_Metadata_Analysis.md` (this file)
- `raw/ghidra_decomp_tier1.txt` — decompile of the media-tier block incl. `FNA_0x005ED890`
  (the +0x88/+0x8C assignments, `IntToHex` path, `FUN_005E9D20` record parse)
- `raw/ghidra_decomp_tier2.txt` — `FUN_008CD3E8` (GetFileAttributesEx DOS reader),
  `FUN_0040D87C/0x0040D8A4` (IntToHex×2), `FUN_005E9D20`, `FNA_0x005EA900`
- `raw/icon_dispatcher_ladder.txt` — full string→ID case harvest (176 rows) + default tail
- `raw/icon_dispatcher_probe.txt` — Ghidra probe: all sampled VAs inside `FUN_008AA010` ±FUN_008A9F90
- `raw/icon_dispatcher_refs.txt` — the dispatcher's single caller
- `raw/icon_wrapper_decomp.txt` — decompile of `FUN_008A9F90` (init vs worker-thread arms)
- `raw/icon_table_xref.txt` — negative result: no imm32 refs to 0x8B3Exx/8B4xxx (explains v4 §8.2's
  "no E8/imm32 to the table")
- `raw/dos_helpers_family.txt`, `raw/immrefs_*.txt`, `raw/thunk_callers.txt` — helper + label-cell
  chains (carried over from earlier milestones)
- scripts (read-only scanners): `icon_table_xref.py`, `va_context.py`, `icon_dispatcher_ladder.py`,
  `dispatcher_entry_callers.py`, `dispatcher_hunt.py`, `thunk_callers.py`,
  `ghidra_scripts/zp_probe.java` (probe/decompile/refs/mkcode/createfun/delstub modes)

## 6. Compliance record

- Zoom Player, the MediaCache (`C:\ProgramData\Zoom Player\MediaCache`), media files, NFOs and
  artwork: never written, deleted, renamed or created; only read/list/stat.
- `zplayer.exe` itself: byte-read only.
- The user's original Ghidra project: never opened or saved; all Ghidra work took place in a
  separate copy project under `%TEMP%\ghidra_full_copy\` (authorized).
- New filesystem writes confined to `investigation_full/` (+ the authorized.Temp copy project).
- The saved TV builder script: untouched.

## 7. Remaining open item

| item | status |
| --- | --- |
| Identity of the Oct-19 23:12:20–23:12:45 wave writer | **unresolved** (see §3) |

Everything else asked across v2–v5 is answered above with the labels shown.
