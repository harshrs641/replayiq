Pod::Spec.new do |s|
  s.name          = 'ReplayIQ'
  s.version       = '1.0.0'
  s.summary       = 'ReplayIQ session replay for iOS: Native DOM or masked screenshot recording, touches, app events and crashes.'
  s.homepage      = 'https://github.com/harshrs641/replayiq'
  s.license       = { :type => 'Commercial', :text => 'Copyright ReplayIQ. All rights reserved.' }
  s.author        = { 'ReplayIQ' => 'sdk@replayiq.dev' }
  s.source        = { :git => 'https://github.com/harshrs641/replayiq.git', :tag => "ios-#{s.version}" }
  s.platform      = :ios, '15.0'
  s.swift_version = '5.9'
  s.source_files  = 'Sources/ReplayIQ/**/*.swift'
  s.frameworks    = 'UIKit', 'SwiftUI', 'ImageIO', 'UniformTypeIdentifiers', 'Compression', 'CryptoKit',
                    'Network', 'AVFoundation', 'Photos', 'CoreLocation', 'UserNotifications'
end
