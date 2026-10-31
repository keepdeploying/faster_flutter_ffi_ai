// The platform-channel path of the demo, as plain Dart types.
//
// Nothing here imports the app. The app wraps these classes in thin adapters
// that implement its `PayloadBridge` and `Classifier` interfaces.

export 'src/channel_classifier.dart';
export 'src/channel_llama_generator.dart';
export 'src/channel_names.dart' show ChannelKind;
export 'src/channel_payload_bridge.dart';
