require 'xcodeproj'

project_path = 'Shirox.xcodeproj'
project = Xcodeproj::Project.open(project_path)

ios_target = project.targets.find { |t| t.name == 'Shirox_iOS' }
mac_target = project.targets.find { |t| t.name == 'Shirox_macOS' }

puts "iOS target: #{ios_target&.name}"
puts "Mac target: #{mac_target&.name}"

# Files to add: [relative path from project root, group path]
new_files = [
  # Models
  ['Shirox/Models/Media.swift',            'Shirox/Models'],
  ['Shirox/Models/UserProfile.swift',      'Shirox/Models'],
  ['Shirox/Models/UserActivity.swift',     'Shirox/Models'],
  ['Shirox/Models/UserNotification.swift', 'Shirox/Models'],
  # Protocols
  ['Shirox/Protocols/MediaProvider.swift', 'Shirox/Protocols'],
  # Services
  ['Shirox/Services/ProviderManager.swift',      'Shirox/Services'],
  ['Shirox/Services/AniListProvider.swift',      'Shirox/Services'],
  ['Shirox/Services/MALAuthManager.swift',       'Shirox/Services'],
  ['Shirox/Services/MALDiscoveryService.swift',  'Shirox/Services'],
  ['Shirox/Services/MALLibraryService.swift',    'Shirox/Services'],
  ['Shirox/Services/MALSocialService.swift',     'Shirox/Services'],
  ['Shirox/Services/MALProvider.swift',          'Shirox/Services'],
  ['Shirox/Services/IDMappingService.swift',     'Shirox/Services'],
  # Views
  ['Shirox/Views/Shared/ProviderStatusBanner.swift', 'Shirox/Views/Shared'],
]

def find_or_create_group(project, group_path)
  parts = group_path.split('/')
  current = project.main_group
  parts.each do |part|
    found = current.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.name == part }
    if found
      current = found
    else
      current = current.new_group(part, part)
    end
  end
  current
end

new_files.each do |file_path, group_path|
  full_path = File.join(File.dirname(project_path), file_path)
  next unless File.exist?(full_path)

  # Check if already added
  existing = project.files.find { |f| f.path == File.basename(file_path) && f.real_path.to_s.include?(File.basename(File.dirname(file_path))) }

  group = find_or_create_group(project, group_path)

  # Check if file reference already exists in this group
  already_in_group = group.children.any? { |c| c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.path == File.basename(file_path) }
  next if already_in_group

  file_ref = group.new_reference(File.basename(file_path))
  file_ref.last_known_file_type = 'sourcecode.swift'

  [ios_target, mac_target].compact.each do |target|
    phase = target.source_build_phase
    unless phase.files_references.include?(file_ref)
      phase.add_file_reference(file_ref)
    end
  end

  puts "Added: #{file_path}"
end

project.save
puts "Project saved."
