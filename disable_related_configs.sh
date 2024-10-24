#!/bin/bash

# Define the configuration file
CONFIG_FILE="x86_64.config"

# Check if the configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found."
    exit 1
fi

# Backup the original config file
BACKUP_FILE="${CONFIG_FILE}.bak_$(date +%Y%m%d%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"

echo "Backup of the original config file created at '$BACKUP_FILE'"

# Extract disabled luci-app package names
disabled_packages=$(grep "^# CONFIG_PACKAGE_luci-app-" "$CONFIG_FILE" | \
                   sed -n 's/^# CONFIG_PACKAGE_luci-app-\(.*\) is not set/\1/p')

# Check if any packages are disabled
if [ -z "$disabled_packages" ]; then
    echo "No disabled luci-app packages found."
    exit 0
fi

echo "Disabled luci-app packages found: $disabled_packages"
echo "----------------------------------------"

# Initialize counters
count_package=0
count_default=0

# Iterate over each disabled package and comment out related settings
for pkg in $disabled_packages; do
    echo "Processing package: $pkg"
    
    # Handle CONFIG_PACKAGE_<pkg>=y
    PACKAGE_PATTERN="^CONFIG_PACKAGE_${pkg}=y"
    if grep -q "$PACKAGE_PATTERN" "$CONFIG_FILE"; then
        # Extract the exact line
        package_line=$(grep "$PACKAGE_PATTERN" "$CONFIG_FILE")
        echo "  Found: $package_line"
        
        # Comment out the line
        sed -i "s|^CONFIG_PACKAGE_${pkg}=y|# CONFIG_PACKAGE_${pkg} is not set|" "$CONFIG_FILE"
        echo "  Commented out CONFIG_PACKAGE_${pkg}"
        count_package=$((count_package + 1))
    else
        echo "  WARNING: CONFIG_PACKAGE_${pkg}=y not found."
    fi

    # Handle CONFIG_DEFAULT_luci-app-<pkg>=y
    DEFAULT_PATTERN="^CONFIG_DEFAULT_luci-app-${pkg}=y"
    if grep -q "$DEFAULT_PATTERN" "$CONFIG_FILE"; then
        # Extract the exact line
        default_line=$(grep "$DEFAULT_PATTERN" "$CONFIG_FILE")
        echo "  Found: $default_line"
        
        # Comment out the line
        sed -i "s|^CONFIG_DEFAULT_luci-app-${pkg}=y|# CONFIG_DEFAULT_luci-app-${pkg} is not set|" "$CONFIG_FILE"
        echo "  Commented out CONFIG_DEFAULT_luci-app-${pkg}"
        count_default=$((count_default + 1))
    else
        echo "  WARNING: CONFIG_DEFAULT_luci-app-${pkg}=y not found."
    fi

    echo "----------------------------------------"
done

echo "Summary:"
echo "  CONFIG_PACKAGE_ lines commented out: $count_package"
echo "  CONFIG_DEFAULT_luci-app_ lines commented out: $count_default"
echo "Configuration file '$CONFIG_FILE' has been updated."

