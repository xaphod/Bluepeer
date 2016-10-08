#
# Be sure to run `pod lib lint filename.podspec' to ensure this is a
# valid spec and remove all comments before submitting the spec.
#
# Any lines starting with a # are optional, but encouraged
#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = "Bluepeer"
  s.version          = "1.0.18"
  s.summary          = "Provides P2P (adhoc) Bluetooth and wifi networking at high-level"
  s.description      = <<-DESC
			Provides P2P (adhoc) Bluetooth and wifi networking at high-level. Uses low-level frameworks like HHServices to have more control than Multipeer and NSNetService.
                       DESC
  s.homepage         = "https://github.com/xaphod/Bluepeer"
  s.license          = 'MIT'
  s.author           = { "Tim Carr" => "xaphod@gmail.com" }
  s.source           = { :git => "https://github.com/xaphod/Bluepeer.git", :tag => s.version.to_s }

  s.platform     = :ios, '8.1'
  s.requires_arc = true
  s.source_files = 'Pod/Classes/*.{swift,m,h}'
  s.resource_bundles = {
    'Bluepeer' => ['Pod/Assets/*.{lproj,storyboard}']
  }
  s.dependency 'CocoaAsyncSocket', '>= 7.4.0'
  s.dependency 'HHServices', '>= 2.0'
  s.dependency 'xaphodObjCUtils'
  #s.public_header_files = 'Pod/Classes/*.h'
  #s.xcconfig = {'OTHER_LDFLAGS' => '-ObjC -all_load'}
  #s.prefix_header_file = 'Pod/Classes/EOSFTPServer-Prefix.pch'
  #s.pod_target_xcconfig = {'SWIFT_INCLUDE_PATHS' => '$(SRCROOT)/Bluepeer/Pod/**'}
  #s.preserve_paths = 'Pod/Classes/module.modulemap'
end
