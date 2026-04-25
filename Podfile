platform :ios, '17.0'

target 'Shirox_iOS' do
  use_frameworks!
  pod 'google-cast-sdk'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    # GoogleCast has no Catalyst support — mark it as iOS-only
    if target.name.include?('GoogleCast') || target.name.include?('google-cast')
      target.build_configurations.each do |config|
        config.build_settings['SUPPORTS_MACCATALYST'] = 'NO'
      end
    end
  end
end
