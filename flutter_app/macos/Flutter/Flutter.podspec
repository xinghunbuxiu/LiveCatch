#
# Local stub so CocoaPods can resolve darwin plugins' `s.ios.dependency 'Flutter'`
# without hitting the Specs CDN (jsdelivr is often blocked). The real macOS
# engine is FlutterMacOS; this pod is not linked into the app.
#
Pod::Spec.new do |s|
  s.name             = 'Flutter'
  s.version          = '1.0.0'
  s.summary          = 'Stub Flutter pod for macOS CocoaPods resolve only.'
  s.homepage         = 'https://flutter.dev'
  s.license          = { :type => 'BSD' }
  s.author           = { 'Flutter Dev Team' => 'flutter-dev@googlegroups.com' }
  s.source           = { :http => 'https://flutter.dev' }
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.vendored_frameworks = 'path/to/nothing'
end
