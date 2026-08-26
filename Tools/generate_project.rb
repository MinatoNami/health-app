#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates HealthExporter.xcodeproj from the source tree.
#
# Run after adding or removing Swift files:
#   gem install xcodeproj --user-install
#   ruby Tools/generate_project.rb
#
# The generated project is committed, so this is only needed when the file list
# changes — you never have to run it just to build.

require 'xcodeproj'
require 'fileutils'

ROOT        = File.expand_path('..', __dir__)
APP_NAME    = 'HealthExporter'
BUNDLE_ID   = 'com.lionelchong.HealthExporter'
SOURCE_DIR  = File.join(ROOT, APP_NAME)
TEST_NAME   = "#{APP_NAME}Tests"
TEST_DIR    = File.join(ROOT, TEST_NAME)
PROJECT_PATH = File.join(ROOT, "#{APP_NAME}.xcodeproj")

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

target = project.new_target(:application, APP_NAME, :ios, '18.0')

# --- Groups mirroring the folder layout -------------------------------------

app_group = project.new_group(APP_NAME, APP_NAME)

swift_files = Dir.glob(File.join(SOURCE_DIR, '**', '*.swift')).sort
grouped = swift_files.group_by { |path| File.dirname(path.sub("#{SOURCE_DIR}/", '')) }

grouped.each do |dir, files|
  group = dir == '.' ? app_group : app_group.new_group(dir, dir)
  files.each do |path|
    ref = group.new_reference(path)
    target.add_file_references([ref])
  end
end

# Info.plist and entitlements are referenced but must not be compiled or copied.
%w[App/Info.plist App/HealthExporter.entitlements].each do |relative|
  full = File.join(SOURCE_DIR, relative)
  next unless File.exist?(full)

  group = app_group.groups.find { |g| g.name == File.dirname(relative) } ||
          app_group.new_group(File.dirname(relative), File.dirname(relative))
  group.new_reference(full)
end

# Asset catalog is a resource.
assets = File.join(SOURCE_DIR, 'Resources', 'Assets.xcassets')
if File.exist?(assets)
  resources_group = app_group.new_group('Resources', 'Resources')
  ref = resources_group.new_reference(assets)
  target.add_resources([ref])
end

# --- Build settings ---------------------------------------------------------

common = {
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
  'IPHONEOS_DEPLOYMENT_TARGET' => '18.0',
  # Swift 5 language mode on purpose: strict Swift 6 concurrency checking turns
  # HealthKit's non-Sendable sample classes into a wall of errors for no
  # behavioural benefit in a single-user app.
  'SWIFT_VERSION' => '5.0',
  'INFOPLIST_FILE' => "#{APP_NAME}/App/Info.plist",
  'CODE_SIGN_ENTITLEMENTS' => "#{APP_NAME}/App/#{APP_NAME}.entitlements",
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'CODE_SIGN_STYLE' => 'Automatic',
  # Set here rather than left blank on purpose. Regenerating overwrites the
  # whole project, so an empty value silently discards the team Xcode wrote
  # into it — the next device build then fails with "requires a development
  # team" and the fix is not obviously related to having added a file.
  # Override with DEVELOPMENT_TEAM=... when running this script.
  'DEVELOPMENT_TEAM' => ENV.fetch('DEVELOPMENT_TEAM', 'MNJZZHXWT8'),
  'TARGETED_DEVICE_FAMILY' => '1',
  'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
  'SDKROOT' => 'iphoneos',
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
  'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
  'ENABLE_PREVIEWS' => 'YES',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'CLANG_ENABLE_MODULES' => 'YES',
  'ALWAYS_SEARCH_USER_PATHS' => 'NO',
  'MARKETING_VERSION' => '1.0',
  'CURRENT_PROJECT_VERSION' => '1'
}

target.build_configurations.each do |config|
  config.build_settings.merge!(common)
  # `@testable import HealthExporter` needs the app module built with
  # testability. Debug enables it by default; setting it explicitly means the
  # test target does not silently stop compiling if that default ever moves.
  config.build_settings['ENABLE_TESTABILITY'] = config.name == 'Debug' ? 'YES' : 'NO'
  if config.name == 'Debug'
    config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone'
    config.build_settings['ONLY_ACTIVE_ARCH'] = 'YES'
  else
    config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = '-O'
    config.build_settings['SWIFT_COMPILATION_MODE'] = 'wholemodule'
  end
end

# --- Unit tests -------------------------------------------------------------
# Host-application tests rather than a standalone logic bundle: the code under
# test is inside the app module, so the bundle has to be loaded into a running
# host to reach it. HealthKit returns nothing in the Simulator, which bounds
# what is worth testing here — the pure parts that have already been wrong once
# (URL building, Django's six-digit timestamps, the sync-failure rule).
test_target = nil
test_files = Dir.glob(File.join(TEST_DIR, '**', '*.swift')).sort
unless test_files.empty?
  test_target = project.new_target(:unit_test_bundle, TEST_NAME, :ios, '18.0')
  test_group = project.new_group(TEST_NAME, TEST_NAME)
  test_files.each do |path|
    test_target.add_file_references([test_group.new_reference(path)])
  end
  test_target.add_dependency(target)

  test_target.build_configurations.each do |config|
    config.build_settings.merge!(
      'PRODUCT_NAME' => '$(TARGET_NAME)',
      'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}Tests",
      'IPHONEOS_DEPLOYMENT_TARGET' => '18.0',
      'SWIFT_VERSION' => '5.0',
      'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGN_STYLE' => 'Automatic',
      'DEVELOPMENT_TEAM' => ENV.fetch('DEVELOPMENT_TEAM', 'MNJZZHXWT8'),
      'TARGETED_DEVICE_FAMILY' => '1',
      'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
      'SDKROOT' => 'iphoneos',
      'TEST_HOST' => "$(BUILT_PRODUCTS_DIR)/#{APP_NAME}.app/#{APP_NAME}",
      'BUNDLE_LOADER' => '$(TEST_HOST)',
      'ALWAYS_SEARCH_USER_PATHS' => 'NO'
    )
  end
end

project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  config.build_settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
end

# --- Frameworks -------------------------------------------------------------
# HealthKit, BackgroundTasks, SwiftUI and OSLog all ship with the SDK and are
# linked automatically by the Swift importer, so no explicit link phase is
# needed. The HealthKit *entitlement* is what actually matters, and that is set
# above via CODE_SIGN_ENTITLEMENTS.
#
# xcodeproj seeds a Frameworks group with an SDK-relative Foundation reference
# that Xcode renders in red because the path doesn't resolve. Harmless, but it
# looks like a broken project, so strip it and the empty group.
target.frameworks_build_phase.clear
project.frameworks_group&.recursive_children&.each(&:remove_from_project)
project.frameworks_group&.remove_from_project

# --- Shared scheme so the target is runnable straight after cloning ----------

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
# In the shared scheme, so `xcodebuild test -scheme HealthExporter` works on a
# fresh clone without anyone opening Xcode to tick a box.
scheme.add_test_target(test_target) if test_target
scheme.save_as(PROJECT_PATH, APP_NAME, true)

# xcodeproj does not write the implicit workspace, and `rm -rf` above removes
# the one Xcode created last time. Builds work without it — Xcode synthesises
# one — but it is committed, so leaving it out makes every regeneration show up
# as a deletion in git, then reappear the next time anyone opens Xcode.
workspace_dir = File.join(PROJECT_PATH, 'project.xcworkspace')
FileUtils.mkdir_p(workspace_dir)
File.write(File.join(workspace_dir, 'contents.xcworkspacedata'), <<~XML)
  <?xml version="1.0" encoding="UTF-8"?>
  <Workspace
     version = "1.0">
     <FileRef
        location = "self:">
     </FileRef>
  </Workspace>
XML

puts "Generated #{PROJECT_PATH}"
puts "  #{swift_files.count} Swift files across #{grouped.keys.count} groups"
puts "  #{test_files.count} test files in #{TEST_NAME}" unless test_files.empty?
puts "  Deployment target: iOS 18.0, Swift 5 language mode"
puts ''
puts 'Next: open in Xcode, set your Team under Signing & Capabilities, and Run.'
