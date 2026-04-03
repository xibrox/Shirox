platform :ios, '17.0'

target 'Shirox_iOS' do
  use_frameworks! :linkage => :static
  pod 'google-cast-sdk'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['FRAMEWORK_SEARCH_PATHS'] ||= ['$(inherited)']
      config.build_settings['FRAMEWORK_SEARCH_PATHS'] << '"$(PODS_ROOT)/google-cast-sdk/GoogleCastSDK-ios-4.8.4_static_xcframework/GoogleCast.xcframework/ios-arm64"'
      config.build_settings['FRAMEWORK_SEARCH_PATHS'] << '"$(PODS_ROOT)/google-cast-sdk/GoogleCastSDK-ios-4.8.4_static_xcframework/GoogleCast.xcframework/ios-arm64_x86_64-simulator"'
    end
  end
end
