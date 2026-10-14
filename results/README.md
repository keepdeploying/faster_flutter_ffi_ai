# Results

Every number on a results slide comes from a file in this folder. Nothing is
typed in by hand, and nothing here comes from an emulator, a simulator or a
debug build. Only real phones, in profile mode.

## What is here

| Path | What it is | In Git |
| --- | --- | --- |
| `raw/` | Everything a benchmark run leaves behind: results files and `flutter drive` logs. | No (`results/raw/` is ignored) |
| `<yyyy-mm-dd>_<model>.json` | A curated run: the results file of one phone, kept on purpose. | Yes |
| `<yyyy-mm-dd>_<model>.md` | The report of that run: Markdown tables. Made by the report tool. | Yes |
| `<yyyy-mm-dd>_<model>/` | The charts of that run as SVG, 1600 x 900 so they drop onto a 16:9 slide. | Yes |

## Naming

A results file is called `<yyyy-mm-dd>_<model>.json`. The date is UTC. The model
is the phone's name in lower case, with every run of other characters turned
into one dash: `Pixel 8 Pro` becomes `pixel-8-pro`.

```text
2026-10-14_pixel-8.json
2026-10-14_iphone-15.json
```

The app writes the name itself. A second run on the same day with the same
phone has the same name and replaces the first one, so copy the one you want to
keep before you run again.

The report and the chart folder take the name of the file without `.json`.

## Raw and curated

Every run lands in `results/raw/`. That folder is a scratch space.

Curate a run when you want to keep it: copy the file one folder up, then commit
it together with its report.

```bash
cp results/raw/2026-10-14_pixel-8.json results/
scripts/report-latest.sh results/2026-10-14_pixel-8.json
git add results/2026-10-14_pixel-8*
```

Keep one file per phone, from a full run (not `--quick`). The benchmark already
runs each suite three times and keeps the run with the median p50
(docs/ARCHITECTURE.md, "Rules for honest numbers").

## Make the report again

The report is a pure function of the JSON file. Run it again whenever the file
or the tool changes. The same file always gives the same report.

```bash
# the newest file in results/raw/
scripts/report-latest.sh

# one file
scripts/report-latest.sh results/2026-10-14_pixel-8.json

# the same, without the script (from the repo root; needs `dart pub get` in tool/ once)
dart run tool/bin/report.dart results/2026-10-14_pixel-8.json --out results/
```

It writes `results/<name>.md` and `results/<name>/`:

| File | What it shows |
| --- | --- |
| `round_trip.svg` | p50 per bridge across payload sizes, log scale, one line per bridge |
| `classify_split.svg` | where one classify call spends its time: preprocess, inference, bridge |
| `jank.svg` | share of janky frames per bridge and execution site |
| `speedup.svg` | one big number: MethodChannel p50 divided by FFI leaf p50 at the model input size |

A chart whose suite is missing from the file is skipped, and the tool says so.
Every chart carries a source line: device, Flutter version, build mode, date.

The file format is in docs/ARCHITECTURE.md ("Results file (schema 1)").
`tool/test/fixtures/` holds made-up files for the tool's own tests. They are not
measurements: never copy them here.
