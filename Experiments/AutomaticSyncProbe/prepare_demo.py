#!/usr/bin/env python3
"""Build a disposable automatic-sync host over an exported committed runtime."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
base = script.parent.parent / "RecordTransportProbe"
subprocess.run(["python3", str(base / "prepare_demo.py"), str(args.demo), str(args.destination)], check=True)
library = args.destination / "Library/Sources/GraphEvo/Experimental"
(library / "GraphCloudTransportDeviceProbe.swift").unlink()
shutil.copyfile(script.with_name("GraphAutomaticCloudDeviceProbe.swift"), library / "GraphAutomaticCloudDeviceProbe.swift")
controller = args.destination / "GraphEvoDemo/RecordTransportProbe.swift"
s = controller.read_text()
old = '["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"]'
new = '["seed", "read-baseline", "periodic-peer", "pause-peer", "update-owner", "update-control-owner", "observe-owner", "reopen-peer", "read-final"]'
if s.count(old) != 1:
    raise RuntimeError("Unexpected base stage dispatcher")
s = s.replace(old, new).replace('GraphCloudTransportDeviceProbe()', 'GraphAutomaticCloudDeviceProbe()')
s = s.replace('"--record-transport"', '"--automatic-sync"').replace('GraphEvo T01', 'GraphEvo T06')
s = s.replace('GraphEvoLaboratory/RecordTransport', 'GraphEvoLaboratory/AutomaticSync')
controller.write_text(s)
app = args.destination / "GraphEvoDemo/AppDelegate.swift"
s = app.read_text()
if s.count('"--record-transport"') != 1:
    raise RuntimeError("Unexpected base app dispatcher")
app.write_text(s.replace('"--record-transport"', '"--automatic-sync"'))
# Wire actual scene aggregation and payload-free, container-scoped notification hints.
s = controller.read_text().replace('["owner", "peer", "fresh"]', '["owner", "peer", "fresh", "current"]')
end = s.rfind("}")
s = s[:end] + '''    func setApplicationActive(_ active: Bool) {
        Task { await probe.setApplicationActive(active) }
    }
    func remoteHint(container: String, scope: String) {
        Task { await probe.remoteHint(container: container, scope: scope) }
    }
''' + s[end:]
controller.write_text(s)
s = app.read_text().replace('import UIKit', 'import UIKit\nimport CloudKit', 1)
end = s.rfind("}")
s = s[:end] + '''    private var activeScenes = Set<String>()
    func sceneActivity(_ scene: UIScene, active: Bool) {
        let id = scene.session.persistentIdentifier
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        (probe as? RecordTransportProbeViewController)?.setApplicationActive(!activeScenes.isEmpty)
    }
''' + s[end:]
s = s.replace('''        completionHandler(.newData)
''', '''        if let notification = CKDatabaseNotification(fromRemoteNotificationDictionary: userInfo),
           notification.containerIdentifier == "iCloud.com.valerioburiani.GraphCKDemo" {
            let scope = notification.databaseScope == .private ? "private" : notification.databaseScope == .shared ? "shared" : "public"
            (probe as? RecordTransportProbeViewController)?.remoteHint(container: notification.containerIdentifier!, scope: scope)
        }
        completionHandler(.noData)
''')
app.write_text(s)
scene = args.destination / "GraphEvoDemo/SceneDelegate.swift"
s = scene.read_text().replace('func sceneDidBecomeActive(_ scene: UIScene) { ProbeLaunchReceipt.mark("sceneDidBecomeActive") }', '''func sceneDidBecomeActive(_ scene: UIScene) {
        ProbeLaunchReceipt.mark("sceneDidBecomeActive")
        (UIApplication.shared.delegate as? AppDelegate)?.sceneActivity(scene, active: true)
    }
    func sceneWillResignActive(_ scene: UIScene) { (UIApplication.shared.delegate as? AppDelegate)?.sceneActivity(scene, active: false) }
    func sceneDidDisconnect(_ scene: UIScene) { (UIApplication.shared.delegate as? AppDelegate)?.sceneActivity(scene, active: false) }''')
scene.write_text(s)
