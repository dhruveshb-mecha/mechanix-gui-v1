#!/usr/bin/env nu

# RPM Packaging Script for Flutter eLinux Apps
# Usage: nu package-rpm.nu <app-name> <output-dir>

# Function to get next RPM release by querying DNF repository
def get_next_rpm_release [
    pkg_name: string,
    app_version: string,
    repo_url: string = "http://pkg.mecha.so/rpm"
] {
    print $"[INFO] Querying DNF repository for existing releases of ($pkg_name)-($app_version)"

    # Check if dnf is available
    if (which dnf | is-empty) {
        print "[WARN] dnf not found on Ubuntu system, starting with release 1"
        print "[WARN] To install: sudo apt install dnf"
        return 1
    }

    try {
        # Add repository configuration if needed
        print $"[INFO] Querying repository: ($repo_url)"

        # Query for all versions of the package
        # Use repoquery for more detailed information
        let query_result = (^dnf repoquery --showduplicates $pkg_name --repofrompath=mechanix-rpm,$repo_url 2>/dev/null | complete)

        if $query_result.exit_code != 0 {
            print "[INFO] Package not found in repository, starting with release 1"
            return 1
        }

        # Parse dnf repoquery output
        # Format: package-name-version-release.arch
        let versions = ($query_result.stdout
            | lines
            | where { |line| ($line | str trim) != "" }
            | where { |line| $line | str contains $pkg_name }
            | each { |line|
                # Extract version-release from package name
                # Example: mechanix-files-1.0.0-1.aarch64 -> 1.0.0-1
                let parts = ($line | str replace $"($pkg_name)-" "" | split row ".")
                if ($parts | length) >= 2 {
                    $parts | first
                } else {
                    null
                }
            }
            | where { |v| $v != null }
        )

        print $"[DEBUG] Versions found in repository: ($versions)"

        # Filter for our upstream version with release number
        # RPM format: version-release (e.g., 1.0.0-1)
        let matching_versions = ($versions
            | where { |v| $v | str starts-with $"($app_version)-" }
        )

        if ($matching_versions | is-empty) {
            print $"[INFO] No releases found for ($app_version), starting with release 1"
            return 1
        }

        # Extract release numbers
        let releases = ($matching_versions
            | each { |v|
                let rel = ($v | str replace $"($app_version)-" "")
                $rel | into int
            }
        )

        let max_release = ($releases | math max)
        let next_release = $max_release + 1

        print $"[INFO] Found existing releases for ($app_version): ($releases | str join ', ')"
        print $"[INFO] Next release will be: ($next_release)"

        return $next_release

    } catch {
        print $"[WARN] Error querying DNF repository: ($in)"
        print "[WARN] Defaulting to release 1"
        return 1
    }
}

def main [
    app_name: string,         # App name from metadata (e.g., "files", "camera")
    output_dir: string,       # Output directory for .rpm file
    --repo-url: string = "http://pkg.mecha.so/comet-rpm"  # Repository URL to query
] {
    # Clean app_name in case user passes a path
    let app_name = ($app_name | path basename)
    
    print $"[INFO] Starting RPM packaging for ($app_name)"
    print "[INFO] Running on Ubuntu system - using cross-platform RPM tools"

    # Check if rpmbuild is available
    if (which rpmbuild | is-empty) {
        print "[ERROR] rpmbuild not found. Please install rpm package on Ubuntu:"
        print "[ERROR]   sudo apt update"
        print "[ERROR]   sudo apt install rpm"
        print "[ERROR]"
        print "[ERROR] Optional: Install dnf for repository queries:"
        print "[ERROR]   sudo apt install dnf"
        exit 1
    }

    # Load packaging metadata
    let metadata_file = "packaging-metadata.yaml"

    if not ($metadata_file | path exists) {
        print $"[ERROR] ($metadata_file) not found in current directory"
        print "[ERROR] Make sure you're running this from the apps/ directory"
        exit 1
    }

    let metadata = open $metadata_file

    # Find app in metadata
    let app = ($metadata.applications | where name == $app_name | first)

    if ($app | is-empty) {
        print $"[ERROR] App '($app_name)' not found in metadata"
        print "[ERROR] Available apps:"
        $metadata.applications | select name folder | print
        exit 1
    }

    let app_folder = $app.folder
    let binary_name = $app.binary
    let app_maintainer = $app.maintainer
    
    # Convert Debian-style dependencies to RPM-style
    # Debian: libc6 (>= 2.38) -> RPM: libc6 >= 2.38
    let dependencies = ($app.dependencies 
        | each { |dep|
            $dep 
            | str replace -r '\s*\(' ' '
            | str replace -r '\)\s*' ''
            | str trim
        }
        | str join ", "
    )

    print $"[INFO] App: ($app_name)"
    print $"[INFO] Folder: ($app_folder)"
    print $"[INFO] Binary: ($binary_name)"

    # Read version from pubspec.yaml
    let pubspec_path = $"($app_folder)/pubspec.yaml"

    if not ($pubspec_path | path exists) {
        print $"[ERROR] pubspec.yaml not found at ($pubspec_path)"
        exit 1
    }

    let pubspec = open $pubspec_path
    let app_version = $pubspec.version
    let app_description = $pubspec.description

    print $"[INFO] Upstream Version: ($app_version)"

    # Get architecture using external uname command
    let pkg_arch = (^uname -m | str trim)
    print $"[INFO] Architecture: ($pkg_arch)"

    # Package name from metadata
    let pkg_name = $"mechanix-($app_name)"

    # Get next RPM release from repository
    let rpm_release = (get_next_rpm_release $pkg_name $app_version $repo_url)
    let pkg_version = $app_version
    let pkg_release = $rpm_release

    print $"[INFO] RPM Release: ($rpm_release)"
    print $"[INFO] Full Package Version: ($pkg_version)-($pkg_release)"

    # Define build directory
    let build_dir = $"($app_folder)/build/elinux/arm64/release/bundle"

    if not ($build_dir | path exists) {
        print $"[ERROR] Build directory not found at ($build_dir)"
        print "[ERROR] Make sure you've run 'flutter-elinux build elinux --release' first"
        exit 1
    }

    # Create RPM build directory structure
    let rpmbuild_root = "rpmbuild"
    let build_root = $"($rpmbuild_root)/BUILDROOT"
    let rpm_root = $"($build_root)/($pkg_name)-($pkg_version)-($pkg_release).($pkg_arch)"

    print $"[INFO] Creating RPM build structure in ($rpmbuild_root)"

    mkdir $"($rpmbuild_root)/SPECS"
    mkdir $"($rpmbuild_root)/BUILD"
    mkdir $"($rpmbuild_root)/RPMS"
    mkdir $"($rpmbuild_root)/SOURCES"
    mkdir $"($rpmbuild_root)/SRPMS"
    mkdir $build_root

    mkdir $"($rpm_root)/usr/bin"
    mkdir $"($rpm_root)/usr/share/mechanix/($pkg_name)/data"
    mkdir $"($rpm_root)/usr/share/mechanix/($pkg_name)/lib"
    mkdir $"($rpm_root)/usr/lib/($pkg_name)"

    # Copy binary
    let binary_src = $"($build_dir)/($binary_name)"
    let binary_dest = $"($rpm_root)/usr/bin/($binary_name)"

    print $"[INFO] Copying binary: ($binary_src) -> ($binary_dest)"

    if not ($binary_src | path exists) {
        print $"[ERROR] Binary not found at ($binary_src)"
        exit 1
    }

    cp $binary_src $binary_dest
    chmod 755 $binary_dest

    # Copy data assets if they exist
    let data_src = $"($build_dir)/data"
    if ($data_src | path exists) {
        print $"[INFO] Copying data assets from ($data_src)"
        let data_items = (ls $data_src)
        if not ($data_items | is-empty) {
            for item in $data_items {
                let dest = $"($rpm_root)/usr/share/mechanix/($pkg_name)/data/(($item.name | path basename))"
                cp -r $item.name $dest
            }
        }
    } else {
        print "[INFO] No data directory found, skipping"
    }

    # Copy lib directory if it exists
    let lib_src = $"($build_dir)/lib"
    if ($lib_src | path exists) {
        print $"[INFO] Copying libraries from ($lib_src)"
        let lib_items = (ls $lib_src)
        if not ($lib_items | is-empty) {
            for item in $lib_items {
                let dest = $"($rpm_root)/usr/share/mechanix/($pkg_name)/lib/(($item.name | path basename))"
                cp -r $item.name $dest
            }
        }
    } else {
        print "[INFO] No lib directory found, skipping"
    }

    # Generate RPM spec file
    print "[INFO] Generating RPM spec file"

    let spec_content = $"Name:           ($pkg_name)
Version:        ($pkg_version)
Release:        ($pkg_release)
Summary:        ($app_description)

License:        Proprietary
URL:            https://mecha.so
BuildArch:      ($pkg_arch)

Requires:       ($dependencies)

%description
($app_description)

%files
/usr/bin/($binary_name)
/usr/share/mechanix/($pkg_name)/*
/usr/lib/($pkg_name)

%changelog
* (date now | format date '%a %b %d %Y') ($app_maintainer)
- Release ($pkg_version)-($pkg_release)
"

    $spec_content | save -f $"($rpmbuild_root)/SPECS/($pkg_name).spec"

    # Create output directory
    mkdir $output_dir

    # Build RPM package
    let rpm_filename = $"($pkg_name)-($pkg_version)-($pkg_release).($pkg_arch).rpm"
    let rpm_path = $"($output_dir)/($rpm_filename)"

    print $"[INFO] Building RPM package: ($rpm_filename)"

    let rpmbuild_result = (^rpmbuild 
        --define $"_topdir ($rpmbuild_root | path expand)"
        --define $"_rpmdir ($output_dir | path expand)"
        --buildroot $"($rpm_root | path expand)"
        -bb 
        $"($rpmbuild_root)/SPECS/($pkg_name).spec"
        | complete)

    if $rpmbuild_result.exit_code != 0 {
        print "[ERROR] RPM build failed:"
        print $rpmbuild_result.stderr
        rm -rf $rpmbuild_root
        exit 1
    }

    # Move the RPM to the expected location
    let built_rpm = $"($output_dir)/($pkg_arch)/($rpm_filename)"
    if ($built_rpm | path exists) {
        mv $built_rpm $rpm_path
        rm -rf $"($output_dir)/($pkg_arch)"
    }

    # Cleanup
    print "[INFO] Cleaning up temporary files"
    rm -rf $rpmbuild_root

    print $"[SUCCESS] ✅ Package created: ($rpm_path)"

    # Return the path for use in CI
    print $rpm_path
}