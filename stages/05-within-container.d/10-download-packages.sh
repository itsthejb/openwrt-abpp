#=abpp
# ---------------------------------------------------------------------------------------------------------------------
# OpenWrt A/B Partition Project
# Copyright (C) 2024 eth-p
# MIT License
# https://github.com/eth-p/openwrt-abpp
# ---------------------------------------------------------------------------------------------------------------------
# This upgrade stage downloads the user's selected packages on the new installation.
# It will also add a uci-defaults script to install them (and subsequently reboot) on first boot.
# ---------------------------------------------------------------------------------------------------------------------

packages_dirname="/packages"
packageslist_filename="packages.list"
packages_log_filename="packages-install.log"

# Ensure /var/lock exists within the new installation.
if ! [ -d "$MOUNTED_ROOT/var/lock" ]; then
    mkdir "$MOUNTED_ROOT/var/lock"
fi

# Create the packages directory.
if ! [ -d "$MOUNTED_WORKDIR/$packages_dirname" ]; then
    echo "Creating packages directory..."
    mkdir "$MOUNTED_WORKDIR/$packages_dirname"
fi

# Copy the packages list.
echo "Copying desired package list..."
grep -v '^#' "$UPGRADE_PACKAGES_FILE" \
    >"$MOUNTED_WORKDIR/$packageslist_filename"

# Select the package manager in the target installation.
package_manager="$(abpp_container_enter "$MOUNTED_ROOT" /bin/ash -c '
    if command -v apk >/dev/null 2>&1; then
        printf apk
    elif command -v opkg >/dev/null 2>&1; then
        printf opkg
    fi
')"
if [ -z "$package_manager" ]; then
    echo "error: neither apk nor opkg is installed in the target installation." 1>&2
    exit 127
fi
echo "Target package manager: $package_manager"
if [ "$package_manager" = apk ]; then
    package_install_command="add --no-network --repositories-file /dev/null --force-non-repository"
    package_archive_pattern="*.apk"
else
    package_install_command="install"
    package_archive_pattern="*.ipk"
fi

# Refresh package indexes within the container.
echo "Fetching available package information with $package_manager..."
TMPDIR= abpp_container_enter "$MOUNTED_ROOT" \
    "$package_manager" update
echo "Package information fetched."

# Download the packages within the container. `apk fetch` writes package archives,
# while opkg's download-only install uses the current directory.
echo "Downloading selected packages..."
if [ "$package_manager" = apk ]; then
    TMPDIR= abpp_container_enter "$MOUNTED_ROOT" /bin/ash -c "\
        set -e; \
        cd '$MOUNTED_WORKDIR_REL/$packages_dirname'; \
        apk fetch --recursive \
            --output '$MOUNTED_WORKDIR_REL/$packages_dirname' \
            \$(grep -v '^#' '$MOUNTED_WORKDIR_REL/$packageslist_filename'); \
        set -- *.apk; \
        [ -f \"\$1\" ] || { echo 'error: apk fetch did not produce any package archives.' 1>&2; exit 1; }
    "
    echo "APK package archives downloaded."
else
    TMPDIR= abpp_container_enter "$MOUNTED_ROOT" /bin/ash -c "\
        cd '$MOUNTED_WORKDIR_REL/$packages_dirname';      \
        cat '$MOUNTED_WORKDIR_REL/$packageslist_filename' \
            | xargs opkg install --download-only
    "
    echo "OPKG package archives downloaded."
fi

# Add an entry to uci-defaults to install the packages on boot.
echo "Preparing uci-default to install packages..."
touch "$MOUNTED_ROOT/etc/uci-defaults/99_abpp_reboot"
cat <<EOF >"$MOUNTED_ROOT/etc/uci-defaults/01_abpp_01_install_packages"
exec >"$MOUNTED_WORKDIR_REL/$packages_log_filename" 2>&1
set -x

if ! $package_manager $package_install_command "$MOUNTED_WORKDIR_REL/$packages_dirname"/$package_archive_pattern; then
    echo "error: failed to install staged packages; leaving them in $MOUNTED_WORKDIR_REL/$packages_dirname" 1>&2
    exit 1
fi
echo 'reboot -d 10' >/etc/uci-defaults/99_abpp_reboot
EOF
echo "First-boot package installation script created."
