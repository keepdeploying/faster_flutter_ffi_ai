#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint channel_bridge.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'channel_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Platform-channel side of the Faster Flutter demo.'
  s.description      = <<-DESC
MethodChannel and BinaryCodec channel handlers for the Faster Flutter demo.
Swift Package Manager is the primary integration; this podspec is the CocoaPods fallback.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'channel_bridge/Sources/channel_bridge/**/*'
  s.dependency 'Flutter'
  # No TensorFlow Lite dependency on purpose: the classifier calls the C API that the
  # flutter_litert pod already links, through dlsym (see TfLiteRuntime.swift and the
  # README). The app must depend on flutter_litert.
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'channel_bridge_privacy' => ['channel_bridge/Sources/channel_bridge/PrivacyInfo.xcprivacy']}
end
