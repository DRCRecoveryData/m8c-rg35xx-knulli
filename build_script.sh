#!/bin/bash

set -e

# Ensure we're in the right directory
cd /build

# Create output directory (in case it wasn't created by Docker)
mkdir -p /build/compiled/m8c

# Build kernel modules
cd /build/linux-4.9.170

echo "Configuring kernel..."
cp /build/linux-sunxi64-legacy.config .config
sed -i 's/# CONFIG_SND_USB_AUDIO is not set/CONFIG_SND_USB_AUDIO=m/g' .config
sed -i 's/# CONFIG_USB_ACM is not set/CONFIG_USB_ACM=m/g' .config

sed -i 's/^YYLTYPE yylloc;$/extern YYLTYPE yylloc;/g' scripts/dtc/dtc-lexer.lex.c_shipped
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_prepare

echo "Building kernel modules..."
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=drivers/usb/class
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=sound/core
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- M=sound/usb

cd /build

# Setup toolchain
echo "Configuring toolchain..."
export XTOOL=$(realpath aarch64-buildroot-linux-gnu_sdk-buildroot)
export XHOST=aarch64-buildroot-linux-gnu
export PATH=$PATH:$XTOOL/bin
export SYSROOT=$XTOOL/$XHOST/sysroot
export PKG_CONFIG_PATH=$SYSROOT/usr/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$SYSROOT

# Build m8c
echo "Building m8c..."
cd /build/m8c
make CC=$XHOST-gcc VERBOSE=1
if [ $? -ne 0 ]; then
    echo "m8c build failed"
    exit 1
fi
cd /build

# Collect files
echo "Collecting files..."

# Copy kernel modules
for module in cdc-acm.ko snd-hwdep.ko snd-usbmidi-lib.ko snd-usb-audio.ko; do
    find /build/linux-4.9.170 -name "$module" -exec cp -v {} /build/compiled/m8c \; || echo "Warning: $module not found"
done

# Copy m8c executable
if [ -f "/build/m8c/m8c" ]; then
    cp -v /build/m8c/m8c /build/compiled/m8c
    echo "Copied m8c executable"
else
    echo "Error: m8c executable not found"
    exit 1
fi

# Create m8c.sh script with config.ini modification check
cat <<'EOF' >/build/compiled/m8c.sh
#!/bin/sh

export HOME=$(dirname $(realpath $0))/m8c
cd $HOME

# Ensure m8c is executable
chmod +x ./m8c

# Load kernel modules
cp *.ko /lib/modules/4.9.170
depmod
modprobe -a cdc-acm snd-hwdep snd-usbmidi-lib snd-usb-audio

# Start audio loopback
pw-loopback -C alsa_input.usb-DirtyWave_M8_14900360-02.analog-stereo -P alsa_output._sys_devices_platform_soc_soc_03000000_codec_mach_sound_card0.stereo-fallback &

# Run m8c once to generate the config.ini file if it doesn't exist
if [ ! -f "$HOME/.local/share/m8c/config.ini" ]; then
    mkdir -p "$HOME/.local/share/m8c/"
    # Run m8c in a way that it exits immediately after generating config.ini
    SDL_GAMECONTROLLERCONFIG="19000000010000000100000000010000,Deeplay-keys,platform:Linux," ./m8c --help >/dev/null 2>&1
fi

# Modify the config.ini file to swap gamepad_select and gamepad_quit if not already modified
CONFIG_FILE="$HOME/.local/share/m8c/config.ini"

if [ -f "$CONFIG_FILE" ]; then
    # Check if the modification has already been done
    if grep -q "^gamepad_select=5" "$CONFIG_FILE" && grep -q "^gamepad_quit=4" "$CONFIG_FILE"; then
        echo "✓ config.ini already contains the correct button mappings."
    else
        echo "Modifying config.ini to swap gamepad_select and gamepad_quit..."
        # Backup the original config.ini
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
        
        # Swap the values
        sed -i 's/^gamepad_select=\(.*\)$/gamepad_select_tmp=\1/' "$CONFIG_FILE"
        sed -i 's/^gamepad_quit=\(.*\)$/gamepad_select=\1/' "$CONFIG_FILE"
        sed -i 's/^gamepad_select_tmp=\(.*\)$/gamepad_quit=\1/' "$CONFIG_FILE"

        echo "✓ config.ini successfully modified."
    fi
else
    echo "Error: config.ini file not found."
    exit 1
fi

# Run m8c with the modified configuration
SDL_GAMECONTROLLERCONFIG="19000000010000000100000000010000,Deeplay-keys,a:b3,b:b4,x:b6,y:b5,leftshoulder:b7,rightshoulder:b8,lefttrigger:b13,righttrigger:b14,guide:b11,start:b10,back:b9,dpup:h0.1,dpleft:h0.8,dpright:h0.2,dpdown:h0.4,volumedown:b1,volumeup:b2,leftx:a0,lefty:a1,leftstick:b12,rightx:a2,righty:a3,rightstick:b15,platform:Linux," ./m8c

# Kill background processes
kill $(jobs -p)
EOF

chmod +x /build/compiled/m8c.sh

#
# Final checks and summary
#
check_build_output() {
    local error_count=0
    local warning_count=0

    # Check m8c executable
    if [ -f "/build/compiled/m8c/m8c" ]; then
        file_type=$(file /build/compiled/m8c/m8c)
        if [[ $file_type == *"ELF 64-bit LSB executable, ARM aarch64"* ]]; then
            echo "✓ m8c executable present and valid"
        else
            echo "✗ m8c executable present but may be invalid: $file_type"
            ((error_count++))
        fi
    else
        echo "✗ m8c executable missing"
        ((error_count++))
    fi

    # Check kernel modules
    modules=("cdc-acm.ko" "snd-hwdep.ko" "snd-usbmidi-lib.ko" "snd-usb-audio.ko")
    for module in "${modules[@]}"; do
        if [ -f "/build/compiled/m8c/$module" ]; then
            echo "✓ Kernel module $module present"
        else
            echo "✗ Kernel module $module missing"
            ((warning_count++))
        fi
    done

    # Check m8c.sh script
    if [ -f "/build/compiled/m8c.sh" ]; then
        if grep -q "SDL_GAMECONTROLLERCONFIG" "/build/compiled/m8c.sh"; then
            echo "✓ m8c.sh script present and contains expected content"
        else
            echo "✗ m8c.sh script present but may be invalid"
            ((warning_count++))
        fi
    else
        echo "✗ m8c.sh script missing"
        ((error_count++))
    fi

    # Print summary
    echo "-------------------"
    echo "Build Check Summary"
    echo "-------------------"
    echo "Errors: $error_count"
    echo "Warnings: $warning_count"

    if [ $error_count -eq 0 ] && [ $warning_count -eq 0 ]; then
        echo "Build completed successfully with no issues."
    elif [ $error_count -eq 0 ]; then
        echo "Build completed with warnings. Please review the output."
    else
        echo "Build completed with errors. Please review the output and correct the issues."
        exit 1
    fi
}

# Run the checks
check_build_output

echo "Build and check process complete. All compiled files are in /build/compiled/m8c"
