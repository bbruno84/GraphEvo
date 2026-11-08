#!/usr/bin/env python3
"""Prepare an external signed authoritative-probe host from a configured host copy."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', required=True, type=Path, help='Configured disposable host with RecordTransportProbe and launch receipts')
parser.add_argument('--output', required=True, type=Path, help='New external directory')
args = parser.parse_args()
repository = Path(__file__).resolve().parents[2]
source, output = args.host.resolve(), args.output.resolve()
if output.exists() or output == repository or repository in output.parents or source == output or source in output.parents:
    parser.error('Use a new external output directory, separate from the input host.')
if not (source/'GraphEvoDemo.xcodeproj/project.pbxproj').is_file() or not (source/'GraphEvoDemo/RecordTransportProbe.swift').is_file():
    parser.error('The source must be a configured authoritative probe host.')
output.mkdir(parents=True, mode=0o700)
shutil.copytree(source, output/'Host', ignore=shutil.ignore_patterns('Library','.git','.build','Build','build','DerivedData'))
library = output/'Host/Library'
library.mkdir()
archive = output/'library.tar'
subprocess.run(['git','-C',str(repository),'archive','--format=tar','--output',str(archive),'HEAD','Package.swift','LICENSE.md','Sources'],check=True)
with tarfile.open(archive) as content:
    content.extractall(library, filter='data')
archive.unlink()
for module, name in [('GraphEvo','GraphCloudActivationDeviceProbe.swift'),('GraphEvoStore','CapacityTransport.swift')]:
    destination = library/'Sources'/module/'Experimental'
    destination.mkdir(exist_ok=True)
    shutil.copy2(Path(__file__).resolve().parent/name,destination/name)
revision = subprocess.check_output(['git','-C',str(repository),'rev-parse','HEAD'],text=True).strip()
(output/'source-commit.txt').write_text(revision+'\n')
print('Prepared external host; preserve its local signing configuration and build Release.')
