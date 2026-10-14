# Design notes

Screens are checked as screenshots at 412 x 915 logical px (Pixel 8, ratio 2.625),
real fonts and icons. Regenerate with `flutter test test/ui --update-goldens`
(needs the `llm_bridge` hook to find llama.cpp; offline, build from a copy of
the app without that dependency, as the UI tests do not use it).
Judged for a projector: can the key number be read from the back row?

## Round 1: bugs and structure
- Race: the five size chips each stretched to full width (a Container with
  `alignment` fills its parent), so they stacked in a column and pushed the
  chart off screen. Now one row of five, number over unit.
- Classify: the time split bar was invisible (a `ColoredBox` with no child has
  no height inside a Row). Fixed with an explicit height.
- Segmented control: "Demo generator" was cut to "Demo gene...". Longer labels
  now get proportionally more width.
- Benchmark: green meant "done", but green means FFI. Done is now ink, running is
  blue. Suite list and results table merged into one list, so the table is on
  screen when the run ends. Table rows: case and median first (28 sp wide), p95
  and p99 quieter below. Button said "Run the benchmark" under a title that said
  the same; it is now "Run all suites".
- Pulse strip 128 to 160 px high, so it is the clear hero on every screen.
- Icons: one theme (weight 400, optical size 24, outline) so strokes are not thin
  from the back row.

## Round 2: balance, icon, density
- Icon redesigned: bolder strokes, a paper-coloured outline under the bolt cuts
  the two bars, so the mark reads at 48 px. Same mark drawn in code (`AppMark`)
  next to the title on Home.
- Race: hero number and Run/Stop button share a row; bars lost 12 dp each, so all
  five bars and the axis fit without scrolling. Axis label that ran off the right
  edge is now clamped.
- Classify and benchmark golden services now offer all three sites, so the site
  control shows its enabled state, as on a phone.
- Filled button colour: white on #4285F4 is 3.6:1, so buttons use #1967D2 (5.4:1).
  The blue accent stays for selection, focus and progress.
- Home copy cut to one line per row; speaker split into name and role.
- Side gutter 20 to 24 (8 px grid).

## Round 3: regressions from the wider gutter, generate screen
- Pulse strip counter column widened so "janky frames" is not cut to "janky".
- Home row icon and arrow narrower so "Run the benchmark" stays on one line.
- Stacked segments: tighter side padding so "Native thread" is not cut.
- Axis labels carry the unit only where it changes (1 µs, 10, 100, 1 ms, 10,
  100), so they no longer touch.
- Generate: first-token time pushed behind the strip. The text box is a fixed
  192 px (six lines) that follows the newest words, so the layout never jumps
  while text streams in; first token is one line, 28 sp.

## Still weak
- Red on white is 3.9:1 and green on white is 3.1:1. Both only colour shapes and
  very large numbers (44 sp and up, where 3:1 is enough). Small text is ink.
- The Classify numbers under the split bar are 20 sp; fine on a phone, small if
  the mirror shows only part of the screen.
- Preview frames in the goldens are the bundled cat photo; the real frames loop.
