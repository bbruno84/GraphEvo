#!/usr/bin/env python3
"""Export a pinned package and add a local-only consumer integration suite."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
here = Path(__file__).resolve().parent
repository = here.parents[1]
destination = args.destination.resolve()
if destination.exists() or destination == repository or repository in destination.parents:
    parser.error('Use a new destination outside the library checkout.')
destination.mkdir()
archive = destination / 'runtime.tar'
subprocess.run(['git', '-C', str(repository), 'archive', '--format=tar', '--output', str(archive), 'HEAD'], check=True)
with tarfile.open(archive) as source:
    source.extractall(destination, filter='data')
archive.unlink()
revision = subprocess.check_output(['git', '-C', str(repository), 'rev-parse', 'HEAD'], text=True).strip()
(destination / 'runtime-revision.txt').write_text(revision + '\n')
for name in ['ConsumerMigrationExample.swift', 'ConsumerMigrationFlowTests.swift']:
    shutil.copyfile(here / name, destination / 'Tests/GraphEvoStoreTests' / name)
hashes = {name: hashlib.sha256((here / name).read_bytes()).hexdigest()
          for name in ['ConsumerMigrationExample.swift', 'ConsumerMigrationFlowTests.swift']}
(destination / 'consumer-laboratory.json').write_text(json.dumps({'shippingRevision': revision, 'overlays': hashes}, indent=2) + '\n')
print('Pinned shipping tree: ' + revision)
print('Local-only laboratory sources copied from: ' + str(here))
