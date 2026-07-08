#!/usr/bin/env ruby
# Removes files from Shirox.xcodeproj (all targets + group refs) and deletes them from disk.
# Usage: ruby scripts/xcode_unregister.rb <path> [<path> ...]
require 'xcodeproj'

paths = ARGV
abort "usage: xcode_unregister.rb <path> ..." if paths.empty?

proj = Xcodeproj::Project.open('Shirox.xcodeproj')

paths.each do |path|
  abs = File.expand_path(path)
  ref = proj.files.find { |f| (f.real_path.to_s == abs) rescue false }
  unless ref
    puts "not registered: #{path}"
    next
  end
  ref.remove_from_project # also removes its build files from all phases
  File.delete(abs) if File.exist?(abs)
  puts "unregistered + deleted: #{path}"
end

proj.save
puts "saved #{proj.path}"
