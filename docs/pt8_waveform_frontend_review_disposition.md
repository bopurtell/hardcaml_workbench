# PT.8 frontend independent findings — final disposition

2026-11-05. Re-executed the original independent probes against A's final sources,
without changing the historical probe sources or receipts:

```bash
python3 -B review_pt8_waveform_frontend/run.py
```

New receipt:
`review_pt8_waveform_frontend/evidence-237cbf389c6e45b48ae4e99ed51503b5/`.

**All76 observations pass; zero remaining findings.** `1.stdout` has72 passes,
including all four previously failing observations. `2.stdout` has four async
digest/late-owner checks passing. Production/test SHA256 inventories are unchanged
across this independent run; final reviewed source hashes are retained in
`source-before.json` / `source-after.json`.

- **R1 resolved:** restored case drift, missing case metadata and MIME drift all
  preserve unavailable saved intent instead of substituting a later sibling VCD.
  Exact saved identities and legitimate JSON-cursor/same-case VCD use still pass.
- **R2 resolved:** explicit palette actions now reject a case absent from captured
  selection, matching the selector and keyboard route.
- Wrong-attempt/case/same-ID, missing metadata, MIME, size/digest, picker and
  ownership fences continue to pass. Historical findings and earlier receipts
  remain accurate evidence of their original source generation.

Verified final terminal SHA256:
`2c301d20dd744e46942e4a4604a7bde475c67f126a8e86c157c9518fe05da698`.
Daemon SHA256:
`ec0108fd3ae65ac8bc8113462bfc1eb4dcdcbecf6410c144fbc982113f495a38`.

The reviewer-only build used switch5.2.0+ox, shared Workbench build lock,
`dune build -j2 --build-dir _build_pt8_workbench`. No frontend production/test
edits, hardware simulation, provider/session changes or EDA in this recheck.
Final real-producer/native integration is recorded separately after this gate.
