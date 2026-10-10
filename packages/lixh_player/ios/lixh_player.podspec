require 'pathname'

Pod::Spec.new do |s|
  s.name             = 'lixh_player'
  s.version          = '0.0.1'
  s.summary          = 'LiveCatch native player (iOS FFmpeg + AudioQueue + FlutterTexture).'
  s.description      = <<-DESC
LiveCatch lixh_player iOS plugin: lixh-player-core + sdk/ios-arm64.
                       DESC
  s.homepage         = 'https://github.com/xinghunbuxiu/liveCatch'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'lixh_player/Sources/lixh_player/**/*.{h,m,swift}',
                   'lixh_player/Sources/lixh_player_corec/**/*.{h,c}'
  s.public_header_files = 'lixh_player/Sources/lixh_player/include/**/*.h',
                          'lixh_player/Sources/lixh_player_corec/include/**/*.h'

  pod_root = Pathname.new(__dir__)
  # In-pod copy produced by packages/lixh_player/ios/sync_ffmpeg_ios.sh
  # (CocoaPods cannot vendor libraries outside the pod root).
  sdk = pod_root + 'Frameworks'
  core = pod_root + '../../../src-tauri/lixh-stream-stack/lixh-player-core'

  unless (sdk + 'include/libavcodec/avcodec.h').exist?
    raise "FFmpeg ios-arm64 not synced into #{sdk}. Run: bash packages/lixh_player/ios/sync_ffmpeg_ios.sh"
  end

  av_names = %w[avformat avcodec avutil swresample]
  av_names.each do |n|
    lib = sdk + "lib/lib#{n}.a"
    raise "Missing #{lib} — run sync_ffmpeg_ios.sh" unless lib.exist?
  end
  s.vendored_libraries = av_names.map { |n| "Frameworks/lib/lib#{n}.a" }

  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.frameworks = 'AudioToolbox', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'UIKit', 'VideoToolbox'
  s.libraries = 'z', 'bz2', 'iconv', 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 arm64',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LIXH_IOS=1',
    'HEADER_SEARCH_PATHS' => "\"#{core}/include\" \"#{sdk}/include\" $(inherited)",
    'LIBRARY_SEARCH_PATHS' => "\"#{sdk}/lib\" $(inherited)",
    'OTHER_CFLAGS' => '$(inherited) -std=c11',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 arm64',
  }
end
