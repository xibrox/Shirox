#!/usr/bin/env ruby
# Registers files into Shirox.xcodeproj (no synchronized groups, so this is required).
# Usage: ruby scripts/xcode_register.rb <source|test|resource> <path> [<path> ...]
#   source   -> added to Shirox_iOS, Shirox_macOS, Shirox_tvOS compile phases
#   test     -> added to ShiroxTests compile phase
#   resource -> added to the three app targets' Copy Bundle Resources phases
# Idempotent: files already referenced are skipped.
require 'xcodeproj'

kind = ARGV.shift
paths = ARGV
abort "usage: xcode_register.rb <source|test|resource> <path> ..." if kind.nil? || paths.empty?

proj = Xcodeproj::Project.open('Shirox.xcodeproj')
app_targets = %w[Shirox_iOS Shirox_macOS Shirox_tvOS].map { |n| proj.targets.find { |t| t.name == n } }
test_target = proj.targets.find { |t| t.name == 'ShiroxTests' }

def group_for(proj, dir)
  g = proj.main_group
  dir.split('/').each do |name|
    child = g.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == name }
    child ||= g.new_group(name, name)
    g = child
  end
  g
end

paths.each do |path|
  abs = File.expand_path(path)
  existing = proj.files.find { |f| (f.real_path.to_s == abs) rescue false }
  if existing
    puts "already registered: #{path}"
    next
  end
  ref = group_for(proj, File.dirname(path)).new_file(abs)
  case kind
  when 'source'
    app_targets.each { |t| t.source_build_phase.add_file_reference(ref, true) }
  when 'test'
    test_target.source_build_phase.add_file_reference(ref, true)
  when 'resource'
    app_targets.each { |t| t.resources_build_phase.add_file_reference(ref, true) }
  else
    abort "unknown kind: #{kind}"
  end
  puts "registered #{kind}: #{path}"
end

proj.save
puts "saved #{proj.path}"
