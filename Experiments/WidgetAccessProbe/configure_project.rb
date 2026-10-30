#!/usr/bin/env ruby
# Uses the separately installed MIT-licensed xcodeproj tool; no tool source is bundled.
require 'xcodeproj'
require 'pathname'
project_path, group_id = ARGV
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |t| t.name == 'GraphEvoDemo' }
raise 'Expected configured demo target' unless app
widget = project.new_target(:app_extension, 'GraphEvoProbeWidget', :ios, '18.0')
widget.product_name = 'GraphEvoProbeWidget'
widget.product_reference.path = 'GraphEvoProbeWidget.appex'
shared = project.main_group.new_group('WidgetProbeShared', 'WidgetProbeShared')
shared_file = shared.new_file('WidgetProbeShared.swift')
app.source_build_phase.add_file_reference(shared_file)
widget.source_build_phase.add_file_reference(shared_file)
source = project.main_group.new_group('WidgetProbeExtension', 'WidgetProbeExtension')
widget.source_build_phase.add_file_reference(source.new_file('GraphEvoProbeWidget.swift'))
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = app.package_product_dependencies.first.package
product.product_name = 'GraphEvo'
widget.package_product_dependencies << product
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product
widget.frameworks_build_phase.files << build_file
app.add_dependency(widget)
embed = app.new_copy_files_build_phase('Embed Widget Extension')
embed.dst_subfolder_spec = '13'
embed.add_file_reference(widget.product_reference).settings = {'ATTRIBUTES' => ['RemoveHeadersOnCopy']}
project.targets.each do |target|
  target.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0' }
end
app.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  config.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['REGISTER_APP_GROUPS'] = 'YES'
end
widget.build_configurations.each do |config|
  original = app.build_configurations.find { |c| c.name == config.name }
  config.base_configuration_reference = original.base_configuration_reference
  settings = config.build_settings
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(WIDGET_PROBE_BUNDLE_IDENTIFIER)'
  team = original.build_settings['DEVELOPMENT_TEAM']
  settings['DEVELOPMENT_TEAM'] = team if team && team != '$(DEVELOPMENT_TEAM)'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_ENTITLEMENTS'] = 'WidgetProbeExtension/WidgetProbe.entitlements'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'WidgetProbeExtension/Info.plist'
  settings['SKIP_INSTALL'] = 'YES'
  settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  settings['SWIFT_VERSION'] = '6.0'
  settings['SWIFT_DEFAULT_ACTOR_ISOLATION'] = 'nonisolated'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  settings['REGISTER_APP_GROUPS'] = 'YES'
  settings['MARKETING_VERSION'] = '1.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
end
project.save
