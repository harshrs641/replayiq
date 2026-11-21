#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint replayiq_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'replayiq_flutter'
  s.version          = '1.0.0'
  s.summary          = 'ReplayIQ session replay for Flutter.'
  s.description      = <<-DESC
ReplayIQ session replay for Flutter: native JPEG encoding and device info.
                       DESC
  s.homepage         = 'https://replayiq.dev'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'ReplayIQ'
  s.source           = { :path => '.' }
  s.source_files = 'replayiq_flutter/Sources/replayiq_flutter/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'replayiq_flutter_privacy' => ['replayiq_flutter/Sources/replayiq_flutter/PrivacyInfo.xcprivacy']}
end
