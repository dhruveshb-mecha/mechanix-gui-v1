#!/usr/bin/env nu

# ============================================================================
# Configuration Constants
# ============================================================================
const INSTALL_PREFIX = "/usr"
const SHARE_BASE = "/usr/share/mechanix"
const DESKTOP_DIR = "/usr/share/applications"
const ICON_DIR = "/usr/share/icons/hicolor/48x48/apps"

const REQUIRED_METADATA_FIELDS = ["name", "binary", "folder"]
const METADATA_FILE = "packaging-metadata.yaml"
const VERSION_RESOLVER = "../utils/resolve-next-version.nu"

# ============================================================================
# Helper Functions
# ============================================================================

# Validates architecture, strips symbols, and copies to destination
def safe-copy [src: path, dest_dir: path, target_arch: string] {
    if not ($src | path exists) { return }
    
    let info = (^file -b $src)
    let is_elf = ($info | str contains "ELF")
    
    if $is_elf {
        let arch_tag = (if $target_arch == "amd64" { "x86-64" } else { "aarch64" })
        if ($info !~ $arch_tag) {
            print $"(ansi yellow)[SKIP] ($src | path basename) is wrong architecture ($info)(ansi reset)"
            return
        }
        if ($info !~ "stripped") {
            print $"[INFO] Stripping ($src | path basename)..."
            try { ^strip $src } catch { print "Strip failed (non-critical)" }
        }
    }
    if not ($dest_dir | path exists) { mkdir $dest_dir }
    cp -r $src $dest_dir
}

# Validates that all required fields exist in metadata
def validate-metadata [app: record] {
    let app_columns = ($app | columns)
    let missing = ($REQUIRED_METADATA_FIELDS | where { |field| 
        not ($field in $app_columns)
    })
    
    if ($missing | is-not-empty) {
        error make { 
            msg: $"Missing required metadata fields: ($missing | str join ', ')" 
        }
    }
    
    # Validate folder exists
    if not ($app.folder | path exists) {
        error make {
            msg: $"Application folder does not exist: ($app.folder)"
        }
    }
}

# Loads and validates metadata
def load-metadata [app_name: string] {
    if not ($METADATA_FILE | path exists) {
        error make { msg: $"Metadata file not found: ($METADATA_FILE)" }
    }
    
    let metadata = (open $METADATA_FILE)
    let app = ($metadata.applications | where name == $app_name | first)
    
    if ($app | is-empty) {
        let available = ($metadata.applications | get name | str join ", ")
        error make { 
            msg: $"App '($app_name)' not found. Available: ($available)" 
        }
    }
    
    validate-metadata $app
    $app
}

# Loads pubspec and validates version format
def load-pubspec [app_folder: path] {
    let pubspec_path = ($app_folder | path join "pubspec.yaml")
    
    if not ($pubspec_path | path exists) {
        error make { msg: $"pubspec.yaml not found in ($app_folder)" }
    }
    
    let pubspec = (open $pubspec_path)
    
    if not ("version" in ($pubspec | columns)) {
        error make { msg: "No version field in pubspec.yaml" }
    }
    
    $pubspec
}

# Resolves build directory with better error messages
def resolve-build-directory [app_folder: path, pkg_arch: string] {
    let arch_dir = (if $pkg_arch == "amd64" { "x64" } else { "aarch64" })
    # Try both naming conventions
    let p1 = ($app_folder | path join "build" "elinux" $arch_dir "release" "bundle")
    let alt_arch = (if $pkg_arch == "amd64" { "x86_64" } else { "arm64" })
    let p2 = ($app_folder | path join "build" "elinux" $alt_arch "release" "bundle")
    
    if ($p1 | path exists) { 
        print $"[INFO] Using build directory: ($p1)"
        return $p1
    } else if ($p2 | path exists) { 
        print $"[INFO] Using alternate build directory: ($p2)"
        return $p2
    } else {
        let tried = [$p1, $p2]
        error make { 
            msg: $"Build directory not found. Tried:\n  ($tried | str join '\n  ')" 
        }
    }
}

# Resolves version with fallback
def resolve-version [pkg_name: string, upstream_version: string] {
    let resolver_path = ($VERSION_RESOLVER | path expand)
    
    if not ($resolver_path | path exists) {
        print $"(ansi yellow)[WARN] Version resolver not found at: ($resolver_path)(ansi reset)"
        return {
            upstream_version: $upstream_version,
            next_revision: "1",
            full_version: $"($upstream_version)-1"
        }
    }
    
    print $"[INFO] Running version resolver: ($resolver_path)"
    
    let result = (do -i {
        ^nu $resolver_path --format "deb" --name $pkg_name --upstream $upstream_version --base-url "http://pkg.mecha.so"
        | complete
    })
    
    if $result.exit_code != 0 {
        print $"(ansi yellow)[WARN] Version resolver failed(ansi reset)"
        return {
            upstream_version: $upstream_version,
            next_revision: "1",
            full_version: $"($upstream_version)-1"
        }
    }
    
    try {
        let parsed = ($result.stdout | from json)
        print $"[INFO] Resolved version: ($parsed.full_version)"
        $parsed
    } catch {
        {
            upstream_version: $upstream_version,
            next_revision: "1",
            full_version: $"($upstream_version)-1"
        }
    }
}

# Validates that binary exists in build directory
def validate-binary [build_dir: path, binary_name: string] {
    let binary_path = ($build_dir | path join $binary_name)
    
    if not ($binary_path | path exists) {
        error make {
            msg: $"Binary not found: ($binary_path)"
        }
    }
    
    $binary_path
}

# Collects and validates artifacts
def collect-artifacts [
    app: record,
    build_dir: path,
    deb_root: path,
    pkg_name: string,
    pkg_arch: string
] {
    print "[INFO] Collecting artifacts..."
    
    # Binary
    let binary_path = (validate-binary $build_dir $app.binary)
    safe-copy $binary_path $"($deb_root)($INSTALL_PREFIX)/bin/" $pkg_arch
    
    # Desktop file
    let desktop_file = $"org.mechanix.($app.name).desktop"
    let desktop_src = ($app.folder | path join $desktop_file)
    let desktop_installed = if ($desktop_src | path exists) {
        print $"[INFO] Installing desktop file: ($desktop_file)"
        let desktop_dest = $"($deb_root)($DESKTOP_DIR)/"
        mkdir $desktop_dest
        cp $desktop_src $desktop_dest
        true
    } else {
        print $"[INFO] No desktop file found: ($desktop_file)"
        false
    }
    
    # Libraries
    let lib_src = ($build_dir | path join "lib")
    let lib_dest = $"($deb_root)($SHARE_BASE)/($pkg_name)/lib/"
    
    if ($lib_src | path exists) {
        let lib_files = (ls $lib_src | where name !~ "(libflutter_engine|libflutter_elinux)")
        if ($lib_files | is-not-empty) {
            print $"[INFO] Installing app-specific libraries"
            $lib_files | each { |item| safe-copy $item.name $lib_dest $pkg_arch }
        }
    }
    
    # Data
    let data_src = ($build_dir | path join "data")
    if ($data_src | path exists) {
        let data_dest = $"($deb_root)($SHARE_BASE)/($pkg_name)/data/"
        mkdir $data_dest
        # Use ls to avoid glob issues in some contexts
        ls $data_src | each { |item| cp -r $item.name $data_dest }
    }
    
    # Icon
    let icon_file = $"mechanix_($app.name).png"
    let icon_src = ($app.folder | path join "assets" $icon_file)
    let icon_installed = if ($icon_src | path exists) {
        print $"[INFO] Installing icon: ($icon_file)"
        let icon_dest = $"($deb_root)($ICON_DIR)/"
        mkdir $icon_dest
        cp $icon_src $icon_dest
        true
    } else {
        false
    }
    
    { 
        desktop_installed: $desktop_installed,
        icon_installed: $icon_installed,
        icon_file: $icon_file
    }
}

# Generates Debian control and maintainer scripts
def generate-debian-files [
    deb_root: path,
    pkg_name: string,
    version_data: record,
    pkg_arch: string,
    app: record,
    pubspec: record
] {
    print "[INFO] Generating DEBIAN control files..."
    let debian_dir = ($deb_root | path join "DEBIAN")
    mkdir $debian_dir
    
    let dependencies = ($app.dependencies? | default [] | str join ", ")
    let description = ($pubspec.description? | default "Mechanix Application")
    let maintainer = ($app.maintainer? | default "Mechanix Team <team@mecha.so>")
    
    let control = $"Package: ($pkg_name)
Version: ($version_data.full_version)
Section: utils
Priority: optional
Architecture: ($pkg_arch)
Maintainer: ($maintainer)
Depends: ($dependencies)
Description: ($description)
"
    $control | save -f ($debian_dir | path join "control")
    
    # postinst
    let postinst = "#!/bin/sh
set -e
update-desktop-database -q || true
if [ -x /usr/bin/gtk-update-icon-cache ]; then
    gtk-update-icon-cache -qtf /usr/share/icons/hicolor || true
fi
"
    $postinst | save -f ($debian_dir | path join "postinst")
    chmod +x ($debian_dir | path join "postinst")
    
    # postrm
    let postrm = "#!/bin/sh
set -e
update-desktop-database -q || true
if [ -x /usr/bin/gtk-update-icon-cache ]; then
    gtk-update-icon-cache -qtf /usr/share/icons/hicolor || true
fi
"
    $postrm | save -f ($debian_dir | path join "postrm")
    chmod +x ($debian_dir | path join "postrm")
}

# ============================================================================
# Main Entry Point
# ============================================================================
def main [
    app_name: string,
    output_dir: string
] {
    print $"(ansi blue)========================================(ansi reset)"
    print $"(ansi blue)DEB Packaging for ($app_name)(ansi reset)"
    print $"(ansi blue)========================================(ansi reset)\n"
    
    let app = (load-metadata $app_name)
    let pubspec = (load-pubspec $app.folder)
    let upstream_version = ($pubspec.version | split row "+" | first)
    
    let raw_arch = (^uname -m | str trim)
    let pkg_arch = (if $raw_arch == "x86_64" { "amd64" } else { "arm64" })
    let pkg_name = $"mechanix-($app_name)"
    
    let version_data = (resolve-version $pkg_name $upstream_version)
    
    let build_dir = (resolve-build-directory $app.folder $pkg_arch)
    
    let deb_root = ($"($env.PWD)/debbuild" | path expand)
    if ($deb_root | path exists) { rm -rf $deb_root }
    mkdir $deb_root
    
    let artifacts = (collect-artifacts $app $build_dir $deb_root $pkg_name $pkg_arch)
    generate-debian-files $deb_root $pkg_name $version_data $pkg_arch $app $pubspec
    
    if not ($output_dir | path exists) { mkdir $output_dir }
    let deb_file = $"($output_dir)/($pkg_name)_($version_data.full_version)_($pkg_arch).deb"
    
    print $"[INFO] Building DEB package..."
    ^dpkg-deb --build $deb_root $deb_file
    
    print $"\n(ansi green)✓ Created: ($deb_file | path basename)(ansi reset)"
    rm -rf $deb_root
}