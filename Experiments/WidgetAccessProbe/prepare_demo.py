#!/usr/bin/env python3
"""Prepare a separate configured GraphEvo demo with a real read-only WidgetKit target."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('demo', type=Path)
parser.add_argument('destination', type=Path)
parser.add_argument('--app-group', default='group.com.example.GraphEvoDemo')
parser.add_argument('--widget-bundle', default='com.example.GraphEvoDemo.GraphEvoProbeWidget')
args = parser.parse_args()
script = Path(__file__).resolve()
subprocess.run([sys.executable, str(script.parent.parent/'PublicMirroredProbe/prepare_demo.py'), str(args.demo), str(args.destination)], check=True)
root = args.destination
for name in ['WidgetProbeOwner.swift', 'WidgetLaboratoryViewController.swift']:
    shutil.copyfile(script.with_name(name), root/'GraphEvoDemo'/name)
shutil.copyfile(script.with_name('WidgetProbeOwnerTests.swift'), root/'GraphEvoDemoTests/WidgetProbeOwnerTests.swift')
for name, folder in [('WidgetProbeShared.swift','WidgetProbeShared'), ('GraphEvoProbeWidget.swift','WidgetProbeExtension')]:
    (root/folder).mkdir(exist_ok=True)
    shutil.copyfile(script.with_name(name), root/folder/name)
p = root/'GraphEvoDemo/AppDelegate.swift'
s = p.read_text().replace('        }\n        return true', '        } else {\n            let controller = WidgetLaboratoryViewController(arguments: args)\n            probe = controller\n        }\n        return true', 1)
p.write_text(s)
info = root/'GraphEvoDemo/Info.plist'
with info.open('rb') as f: content = plistlib.load(f)
content['GraphEvoWidgetAppGroup'] = '$(WIDGET_PROBE_APP_GROUP)'
with info.open('wb') as f: plistlib.dump(content,f)
local = root/'Configuration/Local.xcconfig'
with local.open('a') as f:
    f.write('\nWIDGET_PROBE_APP_GROUP = '+args.app_group+'\nWIDGET_PROBE_BUNDLE_IDENTIFIER = '+args.widget_bundle+'\n')
# Add the group only to the disposable local entitlements that the configured app uses.
for file in [root/'Configuration/Local.entitlements', root/'GraphEvoDemo/GraphEvoDemo.entitlements']:
    with file.open('rb') as f: content = plistlib.load(f)
    content['com.apple.security.application-groups'] = [args.app_group]
    with file.open('wb') as f: plistlib.dump(content,f)
widget = root/'WidgetProbeExtension'
with (widget/'WidgetProbe.entitlements').open('wb') as f:
    plistlib.dump({'com.apple.security.application-groups':[args.app_group]}, f)
with (widget/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleDisplayName':'GraphEvo laboratory','CFBundleExecutable':'$(EXECUTABLE_NAME)',
        'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'$(PRODUCT_NAME)',
        'CFBundlePackageType':'XPC!','CFBundleShortVersionString':'$(MARKETING_VERSION)',
        'CFBundleVersion':'$(CURRENT_PROJECT_VERSION)','GraphEvoWidgetAppGroup':'$(WIDGET_PROBE_APP_GROUP)',
        'NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}, f)
subprocess.run(['ruby',str(script.with_name('configure_project.rb')),str(root/'GraphEvoDemo.xcodeproj'),args.app_group],check=True)
print('Prepared demo/widget copy. Local signing and stores must remain external.')
