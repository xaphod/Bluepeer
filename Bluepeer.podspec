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
  s.version          = "1.4.0"
  s.summary          = "Provides adhoc Bluetooth and wifi networking at high-level"
  s.description      = <<-DESC
			Provides P2P (adhoc) Bluetooth and wifi networking at high-level. Uses low-level frameworks like HHServices to have more control than Multipeer and NSNetService.
                       DESC
  s.homepage         = "https://github.com/xaphod/Bluepeer"
  s.license          = 'MIT'
  s.author           = { "Tim Carr" => "xaphod@gmail.com" }
  s.source           = { :git => "https://github.com/xaphod/Bluepeer.git", :tag => s.version.to_s }

  s.platform     = :ios, '9.0'
  s.requires_arc = true

  s.subspec 'Core' do |core|
    core.source_files = 'Core/*.{swift,m,h}'
    core.resource_bundles = {
      'Bluepeer' => ['Assets/*.{lproj,storyboard}']
    }
    core.dependency 'CocoaAsyncSocket', '>= 7.4.0'
    core.dependency 'HHServices', '>= 2.0'
    core.dependency 'xaphodObjCUtils', '>= 0.0.6'
    core.dependency 'DataCompression', '>= 2.0.0'
  end

  s.subspec 'HotPotatoNetwork' do |hpn|
    hpn.source_files = 'HotPotato/*.{swift,m,h}'
    hpn.dependency 'Bluepeer/Core'
    hpn.dependency 'ObjectMapper', '~> 3.1'
  end

  #s.public_header_files = 'Pod/Classes/*.h'
  #s.xcconfig = {'OTHER_LDFLAGS' => '-ObjC -all_load'}
  #s.prefix_header_file = 'Pod/Classes/EOSFTPServer-Prefix.pch'
  #s.pod_target_xcconfig = {'SWIFT_INCLUDE_PATHS' => '$(SRCROOT)/Bluepeer/Pod/**'}
  #s.preserve_paths = 'Pod/Classes/module.modulemap'
end
