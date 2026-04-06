platform :ios, '17.0'

target 'Shirox_iOS' do
  use_frameworks!
  pod 'google-cast-sdk'
end

post_install do |installer|
  installer.generated_projects.each do |project|
    project.build_configurations.each do |config|
      # no-op
    end
  end
  # Inject Secrets.xcconfig into Pods xcconfig files so build settings are available
  secrets_path = File.expand_path("Secrets.xcconfig", __dir__)
  Dir.glob("Pods/Target Support Files/**/*.xcconfig") do |xcconfig_path|
    content = File.read(xcconfig_path)
    include_line = "#include? \"#{secrets_path}\"\n"
    unless content.include?(include_line)
      File.write(xcconfig_path, include_line + content)
    end
  end
end