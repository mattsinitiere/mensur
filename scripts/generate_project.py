#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib, json
root = Path(__file__).resolve().parents[1]
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(value)
objects = []
def add(key, body): objects.append(f'\t\t{ident(key)} = {{ {body} }};')
def arr(values): return '(' + ', '.join(values) + ', )' if values else '()'
swift = sorted((root/'Mensur').rglob('*.swift'))
refs=[]; builds=[]
for file in swift:
    path=str(file.relative_to(root/'Mensur')); key='file:'+path; build='build:'+path
    add(key,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = "<group>";')
    add(build,f'isa = PBXBuildFile; fileRef = {ident(key)};')
    refs.append(ident(key)); builds.append(ident(build))
resources=[]
for path,kind in [('Assets.xcassets','folder.assetcatalog'),('PrivacyInfo.xcprivacy','text.xml')]:
    add('file:'+path,f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";')
    add('build:'+path,f'isa = PBXBuildFile; fileRef = {ident("file:"+path)};')
    refs.append(ident('file:'+path)); resources.append(ident('build:'+path))
add('file:Info.plist','isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
refs.append(ident('file:Info.plist'))
add('product','isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Mensur.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('appgroup',f'isa = PBXGroup; children = {arr(refs)}; path = Mensur; sourceTree = "<group>";')
add('products',f'isa = PBXGroup; children = {arr([ident("product")])}; name = Products; sourceTree = "<group>";')
add('rootgroup',f'isa = PBXGroup; children = {arr([ident("appgroup"),ident("products")])}; sourceTree = "<group>";')
add('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(builds)}; runOnlyForDeploymentPostprocessing = 0;')
add('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr(resources)}; runOnlyForDeploymentPostprocessing = 0;')
add('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
common={'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'minimal','ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
app={'PRODUCT_BUNDLE_IDENTIFIER':'com.matthewsinitiere.Mensur','PRODUCT_NAME':'$(TARGET_NAME)','TARGETED_DEVICE_FAMILY':'1,2','INFOPLIST_FILE':'Mensur/Info.plist','GENERATE_INFOPLIST_FILE':'NO','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'}
for scope in ['project','app']:
    configs=[]
    for mode in ['Debug','Release']:
        settings=dict(common if scope=='project' else app)
        if scope=='project':
            settings.update({'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO'})
            if mode=='Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG';settings['ONLY_ACTIVE_ARCH']='YES'
        key=f'{scope}:{mode}';configs.append(ident(key))
        text=' '.join(f'{k} = {q(v)};' for k,v in settings.items())
        add(key,f'isa = XCBuildConfiguration; buildSettings = {{ {text} }}; name = {mode};')
    add(scope+':configs',f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target',f'isa = PBXNativeTarget; buildConfigurationList = {ident("app:configs")}; buildPhases = {arr([ident("sources"),ident("frameworks"),ident("resources")])}; buildRules = (); dependencies = (); name = Mensur; productName = Mensur; productReference = {ident("product")}; productType = "com.apple.product-type.application";')
add('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {ident("target")} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {ident("project:configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = {ident("rootgroup")}; productRefGroup = {ident("products")}; projectDirPath = ""; projectRoot = ""; targets = {arr([ident("target")])};')
project=root/'Mensur.xcodeproj'; project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n'+'\n'.join(objects)+'\n\t};\n\trootObject = '+ident('project')+';\n}\n')
scheme=project/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="Mensur.app" BlueprintName="Mensur" ReferencedContainer="container:Mensur.xcodeproj"/>'
(scheme/'Mensur.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated project with {len(swift)} Swift files.')
