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
package_manager="$(abpp_container_enter "$MOUNTED_ROOT" /bin/ash -c \
    'command -v apk >/dev/null 2>&1 && printf apk || command -v opkg >/dev/null 2>&1 && printf opkg')"
if [ -z "$package_manager" ]; then
    echo "error: neither apk nor opkg is installed in the target installation." 1>&2
    exit 127
fi
if [ "$package_manager" = apk ]; then
    package_install_command="add --no-network"
else
    package_install_command="install"
fi

# Refresh package indexes within the container.
echo "Fetching available package information..."
TMPDIR= abpp_container_enter "$MOUNTED_ROOT" \
    "$package_manager" update

# Download the packages within the container. `apk fetch` writes package archives,
# while opkg's download-only install uses the current directory.
echo "Downloading packages..."
if [ "$package_manager" = apk ]; then
    TMPDIR= abpp_container_enter "$MOUNTED_ROOT" /bin/ash -c "\
        cd '$MOUNTED_WORKDIR_REL/$packages_dirname'; \
        apk fetch --recursive \
            \$(grep -v '^#' '$MOUNTED_WORKDIR_REL/$packageslist_filename')
    "
else
    TMPDIR= abpp_container_enter "$MOUNTED_ROOT" /bin/ash -c "\
        cd '$MOUNTED_WORKDIR_REL/$packages_dirname';      \
        cat '$MOUNTED_WORKDIR_REL/$packageslist_filename' \
            | xargs opkg install --download-only
    "
fi

# Add an entry to uci-defaults to install the packages on boot.
echo "Preparing uci-default to install packages..."
touch "$MOUNTED_ROOT/etc/uci-defaults/99_abpp_reboot"
cat <<EOF >"$MOUNTED_ROOT/etc/uci-defaults/01_abpp_01_install_packages"
$package_manager $package_install_command "$MOUNTED_WORKDIR_REL/$packages_dirname"/* \
    && rm -rf "$MOUNTED_WORKDIR_REL/$packages_dirname" \
    && rm "$MOUNTED_WORKDIR_REL/$packageslist_filename" \
    && echo 'reboot -d 10' >/etc/uci-defaults/99_abpp_reboot
EOF
