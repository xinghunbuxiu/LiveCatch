require 'pathname'

#
# CocoaPods path for Flutter macOS (SPM Package.swift kept for local SPM experiments).
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
  # ObjC API public; C/FFmpeg headers private (avoids modular header errors).
  s.public_header_files = 'lixh_player/Sources/lixh_player/include/**/*.h'
  s.private_header_files = 'lixh_player/Sources/lixh_player_corec/include/**/*.h'

  pod_root = Pathname.new(File.expand_path(__dir__))
  sdk = (pod_root + 'Frameworks').cleanpath
  core_include = (pod_root + 'lixh_player/Sources/lixh_player_corec/include').cleanpath

  unless (sdk + 'include/libavcodec/avcodec.h').exist?
    raise "FFmpeg macOS SDK not synced into #{sdk}. Run: bash packages/lixh_player/macos/sync_ffmpeg_macos.sh"
  end
  unless (core_include + 'lixh_player.h').exist?
    raise "lixh_player.h missing at #{core_include}. Run: bash packages/lixh_player/macos/sync_ffmpeg_macos.sh"
  end

  av_names = %w[avformat avcodec avutil swresample]
  av_names.each do |n|
    matches = Dir.glob((sdk + "lib/lib#{n}*.dylib").to_s)
    raise "Missing lib#{n}*.dylib under #{sdk}/lib — run sync_ffmpeg_macos.sh" if matches.empty?
  end
  s.vendored_libraries = av_names.flat_map { |n|
    Dir.glob("Frameworks/lib/lib#{n}*.dylib")
  }.uniq

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.swift_version = '5.0'
  s.frameworks = 'AudioToolbox', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'Cocoa'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LIXH_MACOS=1',
    'HEADER_SEARCH_PATHS' => "\"#{core_include}\" \"#{sdk}/include\" $(inherited)",
    'LIBRARY_SEARCH_PATHS' => "\"#{sdk}/lib\" $(inherited)",
    'LD_RUNPATH_SEARCH_PATHS' => '@loader_path/../Frameworks @executable_path/../Frameworks',
    'OTHER_CFLAGS' => '$(inherited) -std=c11',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
  }
end
