# Command results

Commands were run from the room. Python inspection scripts read only named room files. The script descriptions below identify long inline Python invocations without repeating their entire source. All shell invocations are included; pytest subprocess commands are additionally expanded in runs.json. No git, network, or external-directory inspection command was run.

| # | Command / inline Python operation | Result |
|---:|---|---|
| 1 | `cat RULINGS.md` | Exit0; read R0–R5 before other room inspection. |
| 2 | `ls -a; cat SCOPE.md stub/vblind.py tests/citations.py tests/REPORT.md meter/COMPLIANCE.md saboteurs/SABOTEURS.md` | Exit0; room listing and documents returned; tool display truncated the combined output. Relevant citations/tests/runtime were subsequently reread separately. |
| 3 | `./.venv/bin/python -I citecheck.py . --json audit/citecheck.json` | Exit0;93 citations,93 resolve,77 functions,0 problems,11 unused keys. |
| 4 | Python `-c`: list tests/meter/saboteurs/audit entries and read conftest.py/pytest.ini | Exit0; confirmed fixture loads VBLIND_IMPL by path, puts variant directory on import path, and defaults to stub. |
| 5 | Python `-c`: run nine pytest subprocesses with60-second per-command timeout, bytecode disabled, stub VBLIND_IMPL removed; save logs and runs.json | Parent initially yielded live exec session67553; completion exit0; all nine commands completed without timeout. Individual subprocess results below. |
| 6 | `cat tests/test_dop.py tests/test_iec61937.py tests/test_parse.py tests/helpers.py` | Exit0; read all assertions, refusal checks and fixture builders. |
| 7 | `cat tests/citations.py` | Exit0; read citation entries; aggregate tool display partly truncated, supplemented by later compact extraction and full cited-page reads. |
| 8 | `cat meter/vblind_ref.py` | Exit0; aggregate tool display partly truncated; runtime/policies and all structured comments subsequently extracted separately. |
| 9 | Python `-c`: print citation entries40 onward and beginning of corpus/index.json | Exit0; obtained exact quotes/notes for remaining keys and corpus index layout. |
| 10 | Poll exec session67553, empty stdin,1000ms wait | Completion exit0; reported stub276failed; meter276passed; base276passed; byte_order137failed; dop_bit_order6failed; length_off_by_one4failed; padding11failed; pc_datatype1failed; swapped_markers7failed. This is completion of command5, not a second test run. |
| 11 | Python `-c`: extract31 complete cited pages into audit/source-review.txt and print meter runtime/policies excluding structured comments | Exit0;2911 lines of cited-page evidence; read runtime/constants/open choices. |
| 12 | `sed -n '1,760p' audit/source-review.txt` | Exit0; read DoP and ST337 cited pages, including consumer compatibility and limitations. |
| 13 | `sed -n '761,1535p' audit/source-review.txt` | Exit0; read remaining ST337, ST338, ST340, IEC preview and initial A52 pages. |
| 14 | `sed -n '1536,2240p' audit/source-review.txt` | Exit0; read codec size/header pages and FFmpeg header/source beginning. |
| 15 | `sed -n '2241,2915p' audit/source-review.txt` | Exit0; read FFmpeg source remainder, Annex J syncword context, A52 table continuation and1536-sample duration clause. |
| 16 | Python `-c`: extract74 meter JSON comments, check quote/anchor/tier, save audit/meter-citations.json and three extra pages | Exit0; all74 quotes/anchors found; initial ad hoc tier equality flagged26 FFmpeg entries because index uses secondary-implementation versus R1 secondary. This diagnostic is preserved in meter-citations-initial.json; the supplied checker's explicit alias handling later resolves it with0 actual errors. |
| 17 | `cat tests/REPORT.md` | Exit0; read declared coverage, tier selection, open choices and historical-result caveats. |
| 18 | `cat audit/meter-extra-pages.txt` | Exit0; read A52p.39/p.161 and TS102366p.126 in full. |
| 19 | Python `-c`: print corpus tier labels and initial audit/citecheck.json records | Exit0; confirmed secondary-implementation index alias and test citecheck success. |
| 20 | Python `-c`: parse all fresh JUnit XML, group every killing test, check stub failure messages | Exit0; nine runs each276cases,0skipped; all276 stub failures explicitly NotImplementedError; variant failure counts137/6/4/11/1/7. |
| 21 | Python `-c`: read six variant modules, baseline beginning and citecheck implementation | Exit0; verified single-helper mutations and supplied checker's explicit secondary alias rule. |
| 22 | Python heredoc: enumerate every tests/citations.py key | Exit0;93keys enumerated0..92; no omissions in manual grade plan. |
| 23 | Python heredoc: write audit/build_report.py with manual judgments, matrix/kill extraction and report text | Exit0; created room-local report helper only. |
| 24 | `PYTHONDONTWRITEBYTECODE=1 ./.venv/bin/python audit/build_report.py` | **Exit1**; ModuleNotFoundError: citecheck, because running from audit/ places that directory on Python's initial import path. Report build failed before AUDIT.md was written; this was not a pytest or citation-conformance failure. |
| 25 | Python heredoc: add explicit room cwd to report helper's import path | Exit0; fixed import path for the room-local supplied citecheck.py; no test/implementation/corpus change. |
| 26 | `PYTHONDONTWRITEBYTECODE=1 ./.venv/bin/python audit/build_report.py` | Exit0; wrote AUDIT.md, kills.json, citation-grades.json;81 SUPPORTS,12 PARTIAL,0 DOES-NOT-SUPPORT;74 meter comments,0 supplied-checker errors; all six variants caught. |
| 27 | Python heredoc: write this audit/COMMANDS.md ledger | Exit0; command/result record written. |
| 28 | Python heredoc: final report/artifact validation (recorded below and in validation.json) | Exit0; all required report sections and verdict present,93 grade rows, six kill lists,74 checked meter comments, nine XML/log pairs; exact execution/count consistency verified. |

## Expanded suite results

All commands used `./.venv/bin/python -m pytest tests -q -p no:cacheprovider --junitxml audit/<name>.xml`.

| Environment / XML name | Exit | Result |
|---|---:|---|
| VBLIND_IMPL unset / stub |1|0passed,276failed|
| VBLIND_IMPL=meter/vblind_ref.py / meter |0|276passed,0failed|
| VBLIND_IMPL=saboteurs/base.py / base |0|276passed,0failed|
| VBLIND_IMPL=saboteurs/sab_byte_order.py / sab_byte_order |1|139passed,137failed|
| VBLIND_IMPL=saboteurs/sab_dop_bit_order.py / sab_dop_bit_order |1|270passed,6failed|
| VBLIND_IMPL=saboteurs/sab_length_off_by_one.py / sab_length_off_by_one |1|272passed,4failed|
| VBLIND_IMPL=saboteurs/sab_padding.py / sab_padding |1|265passed,11failed|
| VBLIND_IMPL=saboteurs/sab_pc_datatype.py / sab_pc_datatype |1|275passed,1failed|
| VBLIND_IMPL=saboteurs/sab_swapped_markers.py / sab_swapped_markers |1|269passed,7failed|

All nine suite runs had zero skips and zero collection/import errors. No timeout occurred. Full pytest output is saved in each matching .txt, machine-readable results in .xml, and expanded commands in runs.json. No failed automated check was dropped or converted into a pass.
