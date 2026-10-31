// Plain-language explanation of what this app shows, who it is for and how to
// read what each screen is doing. Opened from the Home screen. No measurements,
// no bridges, text only. The specific numbers that go on the talk's slides
// live on the measurement screens, not here.

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/screen_frame.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenFrame(
      title: 'About',
      measures: false,
      children: const [
        _Lead(
          'This app compares two ways for a Flutter app to reach the native '
          'code on a phone. One is the platform channel, which has been the '
          'standard way since Flutter 1.0. The other is Dart FFI, which calls '
          'into C directly from Dart. On every screen the job is the same, '
          'the model is the same and the input is the same; only the bridge '
          'between Dart and the native side differs. Everything you see is '
          'measured live on your own device.',
        ),

        _Section('The two bridges', [
          _Para(
            'Platform channel. Dart packs the call and its bytes into a '
            'message, the engine carries it over to the platform thread '
            '(Kotlin on Android, Swift on iOS), the native side unpacks, '
            'runs the work and sends a reply back the same way.',
          ),
          _Para(
            'Dart FFI. Dart calls a C function directly on the calling '
            'thread with no message, no unpack and no thread hop. For small '
            'arguments the call is barely more than a C-to-C call. For large '
            'buffers it can skip copying entirely.',
          ),
          _Para(
            'Three flavours of FFI are shown: a plain FFI call with one '
            'copy of the payload (safe for any native function), a "leaf" '
            'FFI call that passes the Dart bytes straight to C with no copy '
            'and no handshake (the native function has to be very short), '
            'and a zero-copy FFI call that '
            'passes a pointer to memory the native side already owns (fastest '
            'per call, but the memory has to live on the native side already).',
          ),
        ]),

        _Section('What each screen shows', [
          _Para(
            'Race the bridges. The same bytes travel through five bridges in '
            'turn; each bridge gets a bar whose length is its median '
            'round-trip time. The point is to see how far FFI drops below the '
            'channels as the payload grows from empty to a 1080p frame. The '
            'gap in time grows with the payload, while the ratio is largest '
            'for tiny calls, where only the fixed cost of the bridge counts.',
          ),
          _Para(
            'Classify frames. One image classifier (MobileNet V1, a small '
            'model from 2017, bundled in the app) runs behind each bridge on '
            'the same photos. The stacked bar splits one classify call into '
            'three parts: preprocess (resize + normalise), inference (the '
            'model itself) and bridge (everything else). The two paths run '
            'the same runtime underneath, so inference is nearly identical. '
            'Preprocessing does the same maths but not in the same language: '
            'Kotlin or Swift on the channel path, C on the FFI path. What '
            'changes is the bridge part, and where the work happens.',
          ),
          _Para(
            'Classify frames also offers three places for the work to run: '
            'the UI thread, a background native thread, and a Dart worker '
            'isolate. The UI thread is where the point of the demo lives: '
            'any work that runs there is work the UI cannot run during, so '
            'frames are dropped. The other two keep the UI free.',
          ),
          _Para(
            'Generate text. Tokens arrive one at a time from a real on-device '
            'language model. The app ships with a small model (SmolLM2 135M, '
            'about 100 MB, bundled in the APK) that always works, and offers '
            'a larger model as an optional upgrade (Qwen2.5 0.5B, about '
            '491 MB, downloaded on demand or pushed from a laptop). Either '
            'model can run through either bridge, which is where the '
            'channel-versus-FFI story shows up for text streaming.',
          ),
          _Para(
            'Run the benchmark. Every suite above, with warm-ups, run three '
            'times; the run with the median result is kept. Saves a '
            'JSON file that the report tool at the repo root turns into '
            'Markdown tables and SVG charts for the slides.',
          ),
        ]),

        _Section('About the pulse strip at the top', [
          _Para(
            'A thin tick for every frame; its height is how long that frame '
            'took. A dashed line marks the frame budget; ticks taller than it '
            'are frames that missed it, drawn in the channel colour. The '
            'number on the right is a running count of frames '
            'that missed the budget. A classify call that blocks the UI '
            'thread shows up here as a tall tick and a jump in the counter.',
          ),
          _Para(
            'If you take nothing else from the demo, it is this: on-device '
            'work that runs on the UI thread costs frames. On-device work '
            'that runs anywhere else does not.',
          ),
        ]),

        _Section('How to read the numbers on each screen', [
          _Para(
            'The number shown is the typical time per call. Half the calls '
            'in a run are faster than it, half are slower. The "slow tail" '
            'you see occasionally comes from the usual sources on a phone: '
            'garbage collection, background work the OS scheduled, and '
            'thermal throttling when the chip gets hot.',
          ),
          _Para(
            'Preprocess and inference are timed on the native side with the '
            'platform\'s monotonic clock. Bridge is the rest of the total '
            'the Dart side measures around the whole call.',
          ),
          _Para(
            'A frame is counted as janky when it takes longer than the '
            'display budget. On a phone with a higher refresh rate the '
            'budget is tighter.',
          ),
        ]),

        _Section('About the benchmark numbers', [
          _Para(
            'Benchmark numbers only count in profile mode on a real phone. '
            'Debug mode is always slower in a way that is not '
            'representative; the app shows a notice and refuses to save a '
            'results file in debug.',
          ),
          _Para(
            'Keep the phone unlocked, awake, on a charger, cool, with Do '
            'Not Disturb on.',
          ),
        ]),

        _Section('The language model file', [
          _Para(
            'SmolLM2 135M (Apache-2.0) is baked into the APK and IPA. It is '
            'enough to show the Generate screen working offline out of the '
            'box, including the pulse strip proving the UI keeps its frames '
            'while tokens stream.',
          ),
          _Para(
            'Qwen2.5 0.5B (Apache-2.0) is the fuller model. It is not '
            'shipped inside the app because the file alone is bigger than '
            'the rest of the app put together. Download it from the Language '
            'models screen over Wi-Fi, or push it from a laptop with '
            'scripts/fetch-models.sh --push. Uninstalling the app or '
            'clearing its storage removes the file; the small bundled model '
            'is unaffected.',
          ),
        ]),
      ],
    );
  }
}

class _Lead extends StatelessWidget {
  const _Lead(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s5),
    child: Text(text, style: AppText.body),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.heading, this.children);
  final String heading;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: Space.s3),
            child: Text(heading, style: AppText.heading),
          ),
        ),
        ...children,
      ],
    ),
  );
}

class _Para extends StatelessWidget {
  const _Para(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s3),
    child: Text(text, style: AppText.body),
  );
}
