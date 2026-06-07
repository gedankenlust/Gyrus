#!/usr/bin/env python3
"""Generates Gyrus.xcodeproj/project.pbxproj with robust recursive group handling"""
import uuid, os

def uid(): return uuid.uuid4().hex[:24].upper()

ROOT = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.path.join(ROOT, "Gyrus")
PROJ_DIR = os.path.join(ROOT, "Gyrus.xcodeproj")
os.makedirs(PROJ_DIR, exist_ok=True)

BUNDLE_ID = "com.gyrus.app"
PRODUCT_NAME = "Gyrus"
SWIFT_VERSION = "5.9"
MACOS_MIN = "26.0"

# 1. Collect all Swift files and their directories
swift_files = []
dirs = set()
for dirpath, _, filenames in os.walk(APP_DIR):
    rel_dir = os.path.relpath(dirpath, ROOT)
    dirs.add(rel_dir)
    for fn in sorted(filenames):
        if fn.endswith(".swift"):
            rel_file = os.path.join(rel_dir, fn)
            swift_files.append(rel_file)

# 2. Assign stable-ish UUIDs
file_refs = {f: (uid(), uid()) for f in swift_files}
# Group UIDs (sorted to be deterministic)
groups = {d: uid() for d in sorted(list(dirs))}

# Special refs
proj_uid = uid()
main_group_uid = uid()
products_group_uid = uid()
app_ref_uid = uid()
sources_phase_uid = uid()
resources_phase_uid = uid()
frameworks_phase_uid = uid()
script_phase_uid = uid()
target_uid = uid()
target_config_list_uid = uid()
proj_config_list_uid = uid()
debug_config_uid = uid()
release_config_uid = uid()
proj_debug_uid = uid()
proj_release_uid = uid()
assets_ref_uid = uid()
assets_build_uid = uid()
infoplist_ref_uid = uid()
xcstrings_ref_uid = uid()
xcstrings_build_uid = uid()

# --- Unit test target machinery ---
test_target_uid = uid()
test_product_ref_uid = uid()
test_config_list_uid = uid()
test_debug_uid = uid()
test_release_uid = uid()
test_sources_phase_uid = uid()
test_group_uid = uid()
test_dep_uid = uid()
test_proxy_uid = uid()

TEST_DIR = os.path.join(ROOT, "GyrusTests")
test_files = sorted(fn for fn in os.listdir(TEST_DIR) if fn.endswith(".swift")) if os.path.isdir(TEST_DIR) else []
test_file_refs = {fn: (uid(), uid()) for fn in test_files}  # fn -> (fileRef, buildFile)

TEST_BUNDLE_ID = BUNDLE_ID + ".tests"

def pbx_file_refs():
    lines = []
    lines.append(f'\t\t{assets_ref_uid} = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
    lines.append(f'\t\t{infoplist_ref_uid} = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    lines.append(f'\t\t{xcstrings_ref_uid} = {{isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = "<group>"; }};')
    lines.append(f'\t\t{app_ref_uid} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {PRODUCT_NAME}.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    for rel, (ref_uid, _) in file_refs.items():
        name = os.path.basename(rel)
        lines.append(f'\t\t{ref_uid} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>"; }};')
    return "\n".join(lines)

def pbx_build_files():
    lines = []
    lines.append(f'\t\t{assets_build_uid} = {{isa = PBXBuildFile; fileRef = {assets_ref_uid}; }};')
    lines.append(f'\t\t{xcstrings_build_uid} = {{isa = PBXBuildFile; fileRef = {xcstrings_ref_uid}; }};')
    for _, (ref_uid, build_uid) in file_refs.items():
        lines.append(f'\t\t{build_uid} = {{isa = PBXBuildFile; fileRef = {ref_uid}; }};')
    return "\n".join(lines)

def pbx_groups():
    lines = []
    # Products
    lines.append(f'\t\t{products_group_uid} = {{isa = PBXGroup; children = ({app_ref_uid}, {test_product_ref_uid},); name = Products; sourceTree = "<group>"; }};')

    # Root Group
    lines.append(f'\t\t{main_group_uid} = {{isa = PBXGroup; children = ({groups["Gyrus"]}, {test_group_uid}, {products_group_uid}); sourceTree = "<group>"; }};')

    # GyrusTests group
    lines.append(test_group_section())

    # All nested groups
    for d in sorted(groups.keys(), key=len, reverse=True):
        g_uid = groups[d]
        name = os.path.basename(d)
        
        # Subgroups: those whose parent is d
        sub_uids = [groups[sub] for sub in sorted(groups.keys()) if os.path.dirname(sub) == d]
        # Files: those in d
        f_uids = [file_refs[f][0] for f in sorted(swift_files) if os.path.dirname(f) == d]
        
        children = sub_uids + f_uids
        
        # Add Resources to Gyrus/Resources group
        if d == "Gyrus/Resources":
            children = [assets_ref_uid, infoplist_ref_uid, xcstrings_ref_uid] + children

        children_str = ",\n\t\t\t\t".join(children)
        if children_str: children_str += ","

        # Special case for the top-level 'Gyrus' group which is at path 'Gyrus' relative to root
        # All others are relative to their parent group
        path = name if d != "Gyrus" else "Gyrus"
        
        lines.append(f'\t\t{g_uid} = {{')
        lines.append(f'\t\t\tisa = PBXGroup;')
        lines.append(f'\t\t\tchildren = (')
        if children_str: lines.append(f'\t\t\t\t{children_str}')
        lines.append(f'\t\t\t);')
        lines.append(f'\t\t\tpath = "{path}";')
        lines.append(f'\t\t\tsourceTree = "<group>";')
        lines.append(f'\t\t}};')
    
    return "\n".join(lines)

def sources_files():
    return "\n".join([f'\t\t\t\t{u[1]},' for u in file_refs.values()])

def test_pbx_build_files():
    return "\n".join(f'\t\t{b} = {{isa = PBXBuildFile; fileRef = {r}; }};' for (r, b) in test_file_refs.values())

def test_pbx_file_refs():
    lines = [f'\t\t{test_product_ref_uid} = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = GyrusTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};']
    for fn, (r, _) in test_file_refs.items():
        lines.append(f'\t\t{r} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{fn}"; sourceTree = "<group>"; }};')
    return "\n".join(lines)

def test_group_section():
    children = "".join(f'\n\t\t\t\t{test_file_refs[fn][0]},' for fn in test_files)
    return (f'\t\t{test_group_uid} = {{\n'
            f'\t\t\tisa = PBXGroup;\n'
            f'\t\t\tchildren = ({children}\n\t\t\t);\n'
            f'\t\t\tpath = GyrusTests;\n'
            f'\t\t\tsourceTree = "<group>";\n'
            f'\t\t}};')

def test_sources_files():
    return "\n".join(f'\t\t\t\t{test_file_refs[fn][1]},' for fn in test_files)

pbxproj = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{pbx_build_files()}
{test_pbx_build_files()}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{pbx_file_refs()}
{test_pbx_file_refs()}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{frameworks_phase_uid} = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
{pbx_groups()}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{target_uid} = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {target_config_list_uid};
\t\t\tbuildPhases = (
\t\t\t\t{sources_phase_uid},
\t\t\t\t{frameworks_phase_uid},
\t\t\t\t{resources_phase_uid},
\t\t\t\t{script_phase_uid},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {PRODUCT_NAME};
\t\t\tproductName = {PRODUCT_NAME};
\t\t\tproductReference = {app_ref_uid};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
\t\t{test_target_uid} = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {test_config_list_uid};
\t\t\tbuildPhases = (
\t\t\t\t{test_sources_phase_uid},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{test_dep_uid},
\t\t\t);
\t\t\tname = GyrusTests;
\t\t\tproductName = GyrusTests;
\t\t\tproductReference = {test_product_ref_uid};
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{proj_uid} = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2650;
\t\t\t\tLastUpgradeCheck = 2650;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target_uid} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t\t{test_target_uid} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t\tTestTargetID = {target_uid};
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {proj_config_list_uid};
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tde,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group_uid};
\t\t\tproductRefGroup = {products_group_uid};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target_uid},
\t\t\t\t{test_target_uid},
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{resources_phase_uid} = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{assets_build_uid},
\t\t\t\t{xcstrings_build_uid},
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
\t\t{script_phase_uid} = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\talwaysOutOfDate = 1;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\tinputPaths = (
\t\t\t\t"$(SRCROOT)/backend",
\t\t\t);
\t\t\tname = "Bundle Python Backend";
\t\t\toutputPaths = (
\t\t\t\t"$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/backend",
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "rsync -a --delete --exclude 'venv' --exclude '__pycache__' --exclude '*.pyc' --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' --exclude '.DS_Store' \\"${{SRCROOT}}/backend/\\" \\"${{BUILT_PRODUCTS_DIR}}/${{UNLOCALIZED_RESOURCES_FOLDER_PATH}}/backend/\\"";
\t\t}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{sources_phase_uid} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{sources_files()}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{test_sources_phase_uid} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{test_sources_files()}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t{test_dep_uid} = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {target_uid};
\t\t\ttargetProxy = {test_proxy_uid};
\t\t}};
/* End PBXTargetDependency section */

/* Begin PBXContainerItemProxy section */
\t\t{test_proxy_uid} = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {proj_uid};
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {target_uid};
\t\t\tremoteInfo = {PRODUCT_NAME};
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin XCBuildConfiguration section */
\t\t{debug_config_uid} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETS_CATALOG_COMPILER_OPTIMIZATION = space;
\t\t\t\tAPP_SANDBOX_ENABLED = NO;
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Gyrus/Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "@executable_path/../Frameworks";
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {MACOS_MIN};
\t\t\t\tMARKETING_VERSION = 0.5.1;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSUPPORTED_PLATFORMS = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{release_config_uid} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETS_CATALOG_COMPILER_OPTIMIZATION = space;
\t\t\t\tAPP_SANDBOX_ENABLED = NO;
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Gyrus/Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "@executable_path/../Frameworks";
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {MACOS_MIN};
\t\t\t\tMARKETING_VERSION = 0.5.1;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSUPPORTED_PLATFORMS = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{proj_debug_uid} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++17";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tCLANG_ANALYZER_LOCALIZABILITY_NONLOCALIZED = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu11;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {MACOS_MIN};
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{proj_release_uid} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++17";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;
\t\t\t\tDEAD_CODE_STRIPPING = YES;
\t\t\t\tCLANG_ANALYZER_LOCALIZABILITY_NONLOCALIZED = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu11;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {MACOS_MIN};
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{test_debug_uid} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {MACOS_MIN};
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{TEST_BUNDLE_ID}";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/{PRODUCT_NAME}.app/Contents/MacOS/{PRODUCT_NAME}";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{test_release_uid} = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = {MACOS_MIN};
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{TEST_BUNDLE_ID}";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = {SWIFT_VERSION};
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/{PRODUCT_NAME}.app/Contents/MacOS/{PRODUCT_NAME}";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{proj_config_list_uid} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{proj_debug_uid},
\t\t\t\t{proj_release_uid},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{target_config_list_uid} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{debug_config_uid},
\t\t\t\t{release_config_uid},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{test_config_list_uid} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{test_debug_uid},
\t\t\t\t{test_release_uid},
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {proj_uid};
}}
"""

out = os.path.join(PROJ_DIR, "project.pbxproj")
with open(out, "w") as f:
    f.write(pbxproj)

# Shared scheme so the app runs and tests can be executed
# (Xcode ⌘U, or `xcodebuild test -scheme Gyrus`).
scheme_dir = os.path.join(PROJ_DIR, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2650" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_uid}" BuildableName="{PRODUCT_NAME}.app" BlueprintName="{PRODUCT_NAME}" ReferencedContainer="container:{PRODUCT_NAME}.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target_uid}" BuildableName="GyrusTests.xctest" BlueprintName="GyrusTests" ReferencedContainer="container:{PRODUCT_NAME}.xcodeproj"/>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_uid}" BuildableName="{PRODUCT_NAME}.app" BlueprintName="{PRODUCT_NAME}" ReferencedContainer="container:{PRODUCT_NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_uid}" BuildableName="{PRODUCT_NAME}.app" BlueprintName="{PRODUCT_NAME}" ReferencedContainer="container:{PRODUCT_NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
with open(os.path.join(scheme_dir, f"{PRODUCT_NAME}.xcscheme"), "w") as f:
    f.write(scheme)
print(f"Test target + scheme written ({len(test_files)} test files)")
print(f"Generated: {out}")
print(f"Swift files included: {len(swift_files)}")
print(f"Groups created: {len(groups)}")
