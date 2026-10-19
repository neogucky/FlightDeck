"""Regenerate the dependency-free Xcode project after adding Swift sources."""
from pathlib import Path
import hashlib

root=Path(__file__).parent
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def ref(name): return uid(name)
objects=[]
def obj(name, body): objects.append(f'{uid(name)} = {{ {body} }};')
sources=sorted((root/'FlightDeck').glob('*.swift'))
tests=sorted((root/'FlightDeckUITests').glob('*.swift'))
for p in sources+tests:
    key=str(p.relative_to(root))
    obj(key,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{p.name}"; sourceTree = "<group>";')
    obj('build:'+key,f'isa = PBXBuildFile; fileRef = {ref(key)};')
obj('info','isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
obj('assets','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
obj('assetsBuild',f'isa = PBXBuildFile; fileRef = {ref("assets")};')
obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = FlightDeck.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('testProduct','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = FlightDeckUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('appGroup',f'isa = PBXGroup; path = FlightDeck; sourceTree = "<group>"; children = ({",".join(ref(str(p.relative_to(root))) for p in sources)},{ref("assets")},{ref("info")},);')
obj('testGroup',f'isa = PBXGroup; path = FlightDeckUITests; sourceTree = "<group>"; children = ({",".join(ref(str(p.relative_to(root))) for p in tests)},);')
obj('products',f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({ref("product")},{ref("testProduct")},);')
obj('root',f'isa = PBXGroup; sourceTree = "<group>"; children = ({ref("appGroup")},{ref("testGroup")},{ref("products")},);')
for name, paths in [('sources',sources),('testSources',tests)]:
    obj(name,f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ref("build:"+str(p.relative_to(root))) for p in paths)},); runOnlyForDeploymentPostprocessing = 0;')
obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ref("assetsBuild")},); runOnlyForDeploymentPostprocessing = 0;')
for name in ['frameworks','testFrameworks']:
    obj(name,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for mode in ['Debug','Release']:
    common='CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; '
    common+=('SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES;' if mode=='Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
    obj('project'+mode,f'isa = XCBuildConfiguration; buildSettings = {{ {common} }}; name = {mode};')
    app='PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = com.flightdeck.personal; INFOPLIST_FILE = FlightDeck/Info.plist; TARGETED_DEVICE_FAMILY = 1; CODE_SIGN_STYLE = Automatic; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; GENERATE_INFOPLIST_FILE = NO; MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 1; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";'
    obj('app'+mode,f'isa = XCBuildConfiguration; buildSettings = {{ {app} }}; name = {mode};')
    test='PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = com.flightdeck.personal.uitests; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = 1; CODE_SIGN_STYLE = Automatic; TEST_TARGET_NAME = FlightDeck;'
    obj('test'+mode,f'isa = XCBuildConfiguration; buildSettings = {{ {test} }}; name = {mode};')
for name in ['project','app','test']:
    obj(name+'Config',f'isa = XCConfigurationList; buildConfigurations = ({ref(name+"Debug")},{ref(name+"Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {ref("appConfig")}; buildPhases = ({ref("sources")},{ref("frameworks")},{ref("resources")},); buildRules = (); dependencies = (); name = FlightDeck; productName = FlightDeck; productReference = {ref("product")}; productType = "com.apple.product-type.application";')
obj('proxy',f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {ref("target")}; remoteInfo = FlightDeck;')
obj('dependency',f'isa = PBXTargetDependency; target = {ref("target")}; targetProxy = {ref("proxy")};')
obj('testTarget',f'isa = PBXNativeTarget; buildConfigurationList = {ref("testConfig")}; buildPhases = ({ref("testSources")},{ref("testFrameworks")},); buildRules = (); dependencies = ({ref("dependency")},); name = FlightDeckUITests; productName = FlightDeckUITests; productReference = {ref("testProduct")}; productType = "com.apple.product-type.bundle.ui-testing";')
obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; TargetAttributes = {{ {ref("target")} = {{ CreatedOnToolsVersion = 26.0; }}; {ref("testTarget")} = {{ CreatedOnToolsVersion = 26.0; TestTargetID = {ref("target")}; }}; }}; }}; buildConfigurationList = {ref("projectConfig")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {ref("root")}; productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; targets = ({ref("target")},{ref("testTarget")},);')
project=root/'FlightDeck.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {ref("project")}; }}\n')
scheme=project/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
def buildref(target,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(target)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:FlightDeck.xcodeproj"/>'
appref=buildref('target','FlightDeck.app');testref=buildref('testTarget','FlightDeckUITests.xctest')
(scheme/'FlightDeck.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{appref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{testref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated',project)
