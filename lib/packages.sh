#!/bin/ash
# ---------------------------------------------------------------------------------------------------------------------
# OpenWrt A/B Partition Project
# Copyright (C) 2024 eth-p
# MIT License
# https://github.com/eth-p/openwrt-abpp
# ---------------------------------------------------------------------------------------------------------------------
# Library script for fetching information about installed packages.
# ---------------------------------------------------------------------------------------------------------------------
# Depends on packages:
#  * apk or opkg (built-in)
# ---------------------------------------------------------------------------------------------------------------------

# Function: abpp_packages_manager
# Prints the installed package manager, preferring `apk` when both are available.
abpp_packages_manager() {
    if command -v apk >/dev/null 2>&1; then
        printf '%s\n' apk
    elif command -v opkg >/dev/null 2>&1; then
        printf '%s\n' opkg
    else
        echo "error: neither apk nor opkg is installed" 1>&2
        return 127
    fi
}

# Function: __abpp_packages_list_installed
# Lists all the packages installed in the given root.
#
# Parameters:
#   $1 -- The root directory to query.
__abpp_packages_list_installed() {
    local root="$1"
    case "$(abpp_packages_manager)" in
        apk)
            awk 'substr($0, 1, 2) == "P:" { print substr($0, 3) }' \
                "$root/lib/apk/db/installed"
            ;;
        opkg)
            printf "%s\n" "$root/usr/lib/opkg/info"/*.list \
                | grep -o '/[^/]\{1,\}$' \
                | sed 's#^/##; s#\.list$##'
            ;;
    esac
}

# Function: __abpp_packages_remove_nonunique
# Removes all packages which appear more than once.
#
# Parameters:
#   &0 -- The packages to filter.
__abpp_packages_remove_nonunique() {
    #  * sort + uniq to count.
    #  * keep lines with only 1 occurrence.
    #  * remove count.

    sort \
        | uniq -c \
        | grep '^[ \t]\{1,\}1 ' \
        | sed 's/^[ \t]\{1,\}1 //'
}

# Function: abpp_packages_resolve_dependencies
# Prints the set of dependencies for all provided packages.
#
# Parameters:
#   &0 -- The packages to query.
abpp_packages_resolve_dependencies() {
    local manager
    manager="$(abpp_packages_manager)"

    while read -r package; do
        if [ "$manager" = apk ]; then
            awk -v package="$package" '
                substr($0, 1, 2) == "P:" { found = (substr($0, 3) == package) }
                found && substr($0, 1, 2) == "D:" { print substr($0, 3); exit }
            ' /lib/apk/db/installed
        else
            grep '^Depends: ' "/usr/lib/opkg/info/$package.control" || true
        fi
    done \
        | sed 's/^Depends: //' \
        | sed 's/([^)]\{1,\})//' \
        | sed 's/, /,/g' \
        | tr ' ,' '\n' \
        | sort -u
}

# Function: abpp_packages_resolve_provides
# Prints the set of features from all provided packages.
#
# Parameters:
#   &0 -- The packages to query.
abpp_packages_resolve_provides() {
    local manager
    manager="$(abpp_packages_manager)"

    while read -r package; do
        if [ "$manager" = apk ]; then
            awk -v package="$package" '
                substr($0, 1, 2) == "P:" { found = (substr($0, 3) == package) }
                found && substr($0, 1, 2) == "p:" { print substr($0, 3); exit }
            ' /lib/apk/db/installed
        else
            grep '^Provides: ' "/usr/lib/opkg/info/$package.control" || true
        fi
    done \
        | sed 's/^Provides: //' \
        | sed 's/([^)]\{1,\})//' \
        | sed 's/, /,/g' \
        | tr ' ,' '\n' \
        | sort -u
}

# Function: abpp_packages_list_all_installed
# Prints a list of all the installed packages.
abpp_packages_list_all_installed() {
    __abpp_packages_list_installed /
}

# Function: abpp_packages_list_baseimage_installed
# Prints a list of all packages that came installed with the rootfs.
abpp_packages_list_baseimage_installed() {
    __abpp_packages_list_installed /rom
}

# Function: abpp_packages_list_user_installed
# Prints a list of all packages installed or updated by the user.
abpp_packages_list_user_installed() {
    # Updates to packages may cause base image packages to appear in overlay.
    # Instead, we use set subtraction (ALL-BASE) to find packages NOT in the
    # base image.
    {
        abpp_packages_list_all_installed
        abpp_packages_list_baseimage_installed
    } | __abpp_packages_remove_nonunique
}

# Function: abpp_packages_list_user_installed
# Prints the list of all packages directly installed by the user.
abpp_packages_list_user_installed_minimal() {
    # Resolve package dependencies and provides in such a way that
    # the only packages which do not appear more than once are
    # packages that the user installed.
    #
    # This may accidentally include packages that are installed
    # as an alternate implementation of a library. Without having
    # support for set operations in ash, it's not possible to fix this.
    {
        abpp_packages_list_all_installed
        abpp_packages_list_baseimage_installed
        abpp_packages_list_user_installed | abpp_packages_resolve_dependencies
        abpp_packages_list_all_installed  | abpp_packages_resolve_provides | sed 'p;p'
    }   | __abpp_packages_remove_nonunique \
        | grep -vwF 'kernel'
}
