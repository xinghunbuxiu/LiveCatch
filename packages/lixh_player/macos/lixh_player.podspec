#
# CocoaPods fallback (Flutter macOS apps using SPM use Package.swift).
#
Pod::Spec.new do |s|
  s.name             = 'lixh_player'
  s.version          = '0.0.1'
  s.summary          = 'LiveCatch native player (macOS FFmpeg + FlutterTexture).'
  s.description      = <<-DESC
LiveCatch lixh_player macOS plugin: lixh-player-core + AudioQueue + FlutterTexture.
                       DESC
  s.homepage         = 'https://github.com/xinghunbuxiu/liveCatch'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files = 'lixh_player/Sources/lixh_player/**/*.{h,m,swift}',
                   'lixh_player/Sources/lixh_player_corec/**/*.{h,c}'
  s.public_header_files = 'lixh_player/Sources/lixh_player/include/**/*.h',
                          'lixh_player/Sources/lixh_player_corec/include/**/*.h'

  core = File.expand_path('../../../src-tauri/lixh-stream-stack/lixh-player-core', __dir__)
  sdk_arm = File.expand_path('../../../src-tauri/lixh-stream-stack/sdk/macos-arm64', __dir__)
  sdk_x64 = File.expand_path('../../../src-tauri/lixh-stream-stack/sdk/macos-x64', __dir__)

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.swift_version = '5.0'
  s.frameworks = 'AudioToolbox', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'Cocoa'
  s.libraries = 'avformat', 'avcodec', 'avutil', 'swresample'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LIXH_MACOS=1',
    'HEADER_SEARCH_PATHS' => "\"#{core}/include\" \"#{sdk_arm}/include\" \"#{sdk_x64}/include\"",
    'LIBRARY_SEARCH_PATHS' => "\"#{sdk_arm}/lib\" \"#{sdk_x64}/lib\"",
    'LD_RUNPATH_SEARCH_PATHS' => "#{sdk_arm}/lib #{sdk_x64}/lib @loader_path/../Frameworks",
    'OTHER_CFLAGS' => '-std=c11',
  }
end
