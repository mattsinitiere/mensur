#!/usr/bin/env python3
"""Portable structural checks. These do not compile Swift or test Apple frameworks."""
from pathlib import Path
import json, plistlib, re, xml.etree.ElementTree as ET
root = Path(__file__).resolve().parents[1]
source = root/'Mensur'
pbx = (root/'Mensur.xcodeproj/project.pbxproj').read_text()
for path in source.rglob('*.swift'):
    rel=str(path.relative_to(source))
    # Xcode quotes a path only when it needs quoting (spaces and the like).
    assert f'path = "{rel}";' in pbx or f'path = {rel};' in pbx, f'Missing Xcode source: {rel}'
for path in [source/'Info.plist',source/'PrivacyInfo.xcprivacy']:
    plistlib.loads(path.read_bytes())
for path in (source/'Assets.xcassets').rglob('Contents.json'):
    manifest=json.loads(path.read_text())
    for image in manifest.get('images',[]):
        assert (path.parent/image['filename']).is_file()
ET.parse(root/'Mensur.xcodeproj/xcshareddata/xcschemes/Mensur.xcscheme')
# Objects are defined at two tabs as `ID /* name */ = {`; deeper IDs (e.g. TargetAttributes keys) are references.
objects=re.findall(r'^\t\t([A-F0-9]{24})(?: /\*.*?\*/)? = \{',pbx,re.M)
assert len(objects)==len(set(objects)), 'Duplicate project object IDs'
refs=re.findall(r'\b[A-F0-9]{24}\b',pbx)
assert set(refs)<=set(objects), 'Dangling PBX reference'
assert 'NSCameraUsageDescription' in plistlib.loads((source/'Info.plist').read_bytes())
print(f'PASS: {len(list(source.rglob("*.swift")))} Swift files referenced; project IDs, scheme XML, plists, and asset paths valid.')
try:
    import tree_sitter, tree_sitter_swift
except ImportError:
    print('SKIP: optional Swift syntax parser not installed. Install tree-sitter and tree-sitter-swift with pip to enable it.')
else:
    parser=tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
    files=list(source.rglob('*.swift')) + list((root/'MensurTests').rglob('*.swift')) + [root/'Package.swift']
    def errors(n):
        if n.type=='ERROR' or n.is_missing: yield n
        for child in n.children: yield from errors(child)
    failures=[]
    for path in files:
        for error in errors(parser.parse(path.read_bytes()).root_node):
            failures.append(f'{path.relative_to(root)}:{error.start_point.row+1}: {error.type}')
    assert not failures, '\n'.join(failures)
    print(f'PASS: Swift syntax parsing of {len(files)} files. Not SDK type-checking or compilation.')
