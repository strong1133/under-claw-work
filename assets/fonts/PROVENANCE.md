# Font Provenance & Integrity Manifest

This directory ships the **D2Coding** fixed-width family plus its licence text as
Flutter assets (see `pubspec.yaml`). D2Coding is free/libre software under the
**SIL Open Font License, Version 1.1** (`OFL.txt`, copied verbatim into this
directory). This manifest records where the binaries came from and their
measured hashes so the "no un-audited external binary" constraint can be
verified after the fact by `tool/font_provenance_check.sh`.

## Upstream source

- Project: **D2Coding** — an open-source fixed-width Korean/Latin coding font.
- Official upstream (canonical release page):
  <https://github.com/naver/d2codingfont/releases>
  (mirror of the original Naver `dev.naver.com` D2Coding project).
- Adopted release: **v1.3.2, Build 20180524** — confirmed by reading the font
  `name` table directly (not assumed); see "Metadata verification" below.

## Honest acquisition note

These `.ttf` files were **not** freshly downloaded from the upstream URL during
this session. They were adopted from a local sibling repository in the same
workspace, `underjoy-work-log`
(`apps/worklog_studio/assets/fonts/D2Coding.ttf`), whose `D2Coding.ttf` has a
**byte-identical SHA-256** to the copy here
(`8b1b23e5de4dff652fb0b938528150d2f531edfda281d3944618b655711aba84`),
confirming they are the same artifact. The upstream URL above is the authorative
origin of that artifact, recorded here so the chain of custody is auditable; the
hashes below are what actually ships in *this* repo and are what the verify
script gates on. `D2Coding-Bold.ttf` was carried alongside the regular face from
the same D2Coding v1.3.2 release (the sibling repo tracks only the regular face,
so the Bold face's identity is anchored by its own recorded hash and `name`
table below rather than by a sibling match).

## Measured integrity (SHA-256)

Computed with `shasum -a 256` against the files as committed:

| File                | SHA-256                                                            | Size (bytes) |
| ------------------- | ----------------------------------------------------------------- | ------------ |
| `D2Coding.ttf`      | `8b1b23e5de4dff652fb0b938528150d2f531edfda281d3944618b655711aba84` | 4185844      |
| `D2Coding-Bold.ttf` | `dde75df435f061eaa0f6db84b1c30866aaa442d7038aaa62ea3c2be92f15d87d` | 4359956      |
| `OFL.txt`           | `d189459520c1e22ffaa52bf12265c210b9203b337bf4f8891c206ba6441b0e2c` | 4382         |

`tool/font_provenance_check.sh` re-computes these and exits non-zero on any
mismatch. It is **not** a hypothetical hook: it runs as a continuous gate in the
`secret-scan` job of `.github/workflows/ci.yml` (the step immediately after
`bash tool/secret_scan.sh`), so every pull request and every push to `main`
re-verifies these hashes. Note the standing condition for that gate to be
effective: the font assets in this directory (`D2Coding.ttf`,
`D2Coding-Bold.ttf`, `OFL.txt`) must be committed to the repository — the CI
checkout only sees committed files, so until the fonts are committed the gate
step runs but has nothing to verify (and would fail closed on a missing file
once its manifest row exists).

## Metadata verification (read from the font `name` table)

Verified by inspecting the embedded `name` table strings of each `.ttf`
(`strings -a <file>`), i.e. the fonts' own metadata rather than any external
claim:

- `D2Coding.ttf` → `D2Coding Regular`, `Version 1.3.2; Build 20180524`,
  designer strings `Yong-Rak Park; Jeong-Hwan Yoon; Sang-Min Lee`, foundry
  `FONTRIX Inc.` / `NHN Corporation`.
- `D2Coding-Bold.ttf` → `D2Coding Bold`, `Version 1.3.2; Build 20180524`, same
  designers/foundry.

## Attribution cross-check (OFL.txt vs. font `name` table)

There is a **known, benign discrepancy** in the copyright holder wording between
the licence file and the font binaries, recorded here honestly:

- `OFL.txt` copyright line:
  `Copyright (c) Naver Corporation (D2Coding), with Reserved Font Name
  "D2Coding".`
- Font `name` table copyright (both faces):
  `Copyright (c) 2015-2016 NHN Corporation. All rights reserved. Font designed
  by FONTRIX Inc.`

Both refer to the same D2Coding project: the font was produced under NHN
Corporation (the original publisher of D2Coding, designed by FONTRIX Inc.) and
is distributed via Naver's open-source channel, which is why the OFL header
attributes it to Naver Corporation. This is an upstream attribution nuance, not
a sign of tampering — the binaries' own metadata (NHN 2015-2016) is the primary
authorship record and the OFL grant (SIL OFL 1.1) is identical either way. The
`name` table also embeds the OFL notice and a licence URL
(`This Font Software is licensed under the SIL Open Font License, Version 1.1`),
consistent with the bundled `OFL.txt`.
