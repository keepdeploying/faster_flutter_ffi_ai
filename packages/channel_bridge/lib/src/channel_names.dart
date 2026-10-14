/// Channel names and method names. Kotlin and Swift use the same strings;
/// docs/ARCHITECTURE.md lists them.
abstract final class ChannelNames {
  static const method = 'faster_flutter/method';
  static const binary = 'faster_flutter/binary';

  static const roundTrip = 'roundTrip';
  static const loadModel = 'loadModel';
  static const classify = 'classify';
}

/// Which channel setup carries the bytes.
enum ChannelKind {
  /// `MethodChannel` + `StandardMessageCodec`: the default most plugins use.
  /// The call is encoded into a message, copied across, decoded, dispatched by
  /// method name, and the reply goes back the same way.
  method,

  /// `BasicMessageChannel<ByteData?>` + `BinaryCodec`: no encoding step. The
  /// bytes cross as they are. This is the setup the Flutter team measured as
  /// the fastest channel setup ("Improving Platform Channel Performance in
  /// Flutter", Flutter blog, 2021).
  binary,
}
