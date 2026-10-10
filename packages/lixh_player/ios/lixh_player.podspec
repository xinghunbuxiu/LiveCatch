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

  core = File.expand_path('../../../src-tauri/lixh-stream-stack/lixh-player-core', __dir__)
  sdk = File.expand_path('../../../src-tauri/lixh-stream-stack/sdk/ios-arm64', __dir__)

  unless File.exist?(File.join(sdk, 'include/libavcodec/avcodec.h'))
    raise "FFmpeg ios-arm64 SDK missing at #{sdk}. Run: bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh ios-arm64"
  end

  # Static archives from LiveCatchFfmpeg (device arm64).
  s.vendored_libraries = %w[avformat avcodec avutil swresample].map { |n|
    File.join(sdk, "lib/lib#{n}.a")
  }

  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.frameworks = 'AudioToolbox', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'UIKit', 'VideoToolbox'
  s.libraries = 'z', 'bz2', 'iconv', 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 arm64',
    'ONLY_ACTIVE_ARCH[sdk=iphonesimulator*]' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LIXH_IOS=1',
    'HEADER_SEARCH_PATHS' => "\"#{core}/include\" \"#{sdk}/include\" $(inherited)",
    'LIBRARY_SEARCH_PATHS' => "\"#{sdk}/lib\" $(inherited)",
    'OTHER_CFLAGS' => '$(inherited) -std=c11',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 arm64',
    'LIBRARY_SEARCH_PATHS' => "\"#{sdk}/lib\" $(inherited)",
  }
end
