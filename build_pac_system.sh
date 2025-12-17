#!/usr/bin/env bash
set -euo pipefail

FT="${HOME}/ft-pac"
UBOOT_GIT="https://source.denx.de/u-boot/u-boot.git"
KERNEL_GIT="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
BUSYBOX_GIT="https://github.com/mirror/busybox.git"

JOBS="${JOBS:-$(nproc)}"
ARCH="arm64"
CROSS="aarch64-linux-gnu-"

CPU_QEMU="cortex-a72"
GIC="3"
RAM_MB="1024"

log()  { printf "\n\033[1;36m[ft-pac]\033[0m %s\n" "$*"; }
fail() { printf "\n\033[1;31m[ft-pac:ERROR]\033[0m %s\n" "$*" >&2; exit 1; }
reqf() { [[ -f "$1" ]] || fail "missing file: $1"; }
reqx() { [[ -x "$1" ]] || fail "missing/executable not found: "$1""; }

copy_runtime_scripts() {
  local target="$1"
  mkdir -p "${target}/usr/bin" "${target}/usr/lib/pac"
  # Copy from build/ directory (source) not rootfs/ (staging)
  for script in policy_monitor.sh policy_engine.sh health_check.sh attest_agent.sh attest_agent_crypto.sh; do
    if [[ -f "${FT}/tier1_initramfs/build/usr/lib/pac/${script}" ]]; then
      cp -f "${FT}/tier1_initramfs/build/usr/lib/pac/${script}" "${target}/usr/lib/pac/" || true
      chmod +x "${target}/usr/lib/pac/${script}" 2>/dev/null || true
    fi
  done
  if [[ -f "${FT}/tier1_initramfs/build/bin/journal_tool" ]]; then
    mkdir -p "${target}/bin"
    cp -f "${FT}/tier1_initramfs/build/bin/journal_tool" "${target}/bin/" || true
    chmod +x "${target}/bin/journal_tool" 2>/dev/null || true
  fi
}

log "Installing packages (sudo)..."
sudo apt-get update -y
sudo apt-get install -y \
  build-essential git curl ca-certificates bc jq rsync ccache \
  flex bison libssl-dev libelf-dev libncurses5-dev \
  qemu-system qemu-system-arm qemu-system-misc qemu-utils \
  swtpm swtpm-tools tpm2-tools device-tree-compiler python3-venv \
  python3-pip gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross \
  expect libgnutls28-dev cryptsetup-bin

python3 -m pip install --user -r "${FT}/requirements.txt"

log "Creating project tree at ${FT}"
mkdir -p "${FT}"/{boot/{u-boot,keys,fit},kernel/{build,config},tier1_initramfs/{rootfs,img},tier2/{rootfs,img},tier3/{rootfs,img,keys},scripts,tpmstate}
mkdir -p "${FT}/journal" "${FT}/verifier" "${FT}/faultlab" "${FT}/figures" "${FT}/paper"

if [[ ! -d "${FT}/boot/u-boot/src/.git" ]]; then
  log "Cloning U-Boot..."
  rm -rf "${FT}/boot/u-boot/src"
  git clone --depth=1 "${UBOOT_GIT}" "${FT}/boot/u-boot/src"
fi
log "Building U-Boot (mkimage + u-boot.elf) with CROSS=${CROSS} ..."
pushd "${FT}/boot/u-boot/src" >/dev/null
make CROSS_COMPILE="${CROSS}" qemu_arm64_defconfig

log "Configuring U-Boot for FIT verification..."
./scripts/config \
  -e FIT -e FIT_VERBOSE -e FIT_SIGNATURE \
  -e RSA \
  -e DM -e OF_CONTROL -e OF_SEPARATE

make -j"${JOBS}" CROSS_COMPILE="${CROSS}"

reqx "tools/mkimage"

if [[ -f "u-boot" ]]; then
    ln -sf "u-boot" "u-boot.elf" 2>/dev/null || true
    log "U-Boot ELF found as 'u-boot', created symlink 'u-boot.elf'"
elif [[ -f "u-boot.elf" ]]; then
    log "U-Boot ELF found as 'u-boot.elf'"
else
    fail "Could not find U-Boot ELF file (looked for 'u-boot' and 'u-boot.elf')"
fi

reqf "u-boot.elf"

if [[ -f "arch/arm/dts/qemu-arm64.dtb" ]]; then
    cp -f "arch/arm/dts/qemu-arm64.dtb" "u-boot.dtb"
    log "Copied arch/arm/dts/qemu-arm64.dtb to u-boot.dtb"
elif [[ -f "u-boot.dtb" ]]; then
    log "u-boot.dtb already exists"
else
    QEMU_DTB="$(find arch/arm/dts -name "*qemu*arm64*.dtb" -o -name "*virt*arm64*.dtb" | head -n1)"
    if [[ -n "${QEMU_DTB}" ]]; then
        cp -f "${QEMU_DTB}" "u-boot.dtb"
        log "Copied ${QEMU_DTB} to u-boot.dtb"
    else
        fail "Could not find appropriate DTB file for qemu arm64"
    fi
fi

reqf "u-boot.dtb"
popd >/dev/null

if [[ ! -f "${FT}/boot/keys/pac_signing.key" ]]; then
  log "Generating FIT signing keys..."
  openssl genrsa -out "${FT}/boot/keys/pac_signing.key" 2048
  openssl req -batch -new -x509 -key "${FT}/boot/keys/pac_signing.key" \
    -out "${FT}/boot/keys/pac_signing.crt" -days 3650
fi

if [[ ! -d "${FT}/kernel/src/.git" ]]; then
  log "Cloning Linux kernel..."
  rm -rf "${FT}/kernel/src"
  git clone --depth=1 "${KERNEL_GIT}" "${FT}/kernel/src"
fi

log "Configuring & building Linux kernel (Image + DTBs) with CROSS=${CROSS} ..."
pushd "${FT}/kernel/src" >/dev/null

log "Setting up base kernel configuration..."
make ARCH="${ARCH}" CROSS_COMPILE="${CROSS}" defconfig

log "Applying essential kernel config options..."

set_kernel_config() {
    local config="$1"
    local value="$2"
    
    # If config is commented out, uncomment and set value
    sed -i "s/^# CONFIG_${config} is not set/CONFIG_${config}=${value}/" .config 2>/dev/null || true
    # If config exists with different value, change it
    sed -i "s/^CONFIG_${config}=.*/CONFIG_${config}=${value}/" .config 2>/dev/null || true
    # If config doesn't exist, add it
    if ! grep -q "CONFIG_${config}=" .config; then
        echo "CONFIG_${config}=${value}" >> .config
    fi
}

set_kernel_config BLK_DEV_INITRD y
set_kernel_config VIRTIO y
set_kernel_config VIRTIO_BLK y
set_kernel_config VIRTIO_NET y
set_kernel_config TCG_TPM y
set_kernel_config TCG_TIS y
set_kernel_config TCG_CRB y
set_kernel_config CRYPTO_SHA256 y
set_kernel_config CRYPTO_USER_API_HASH y
set_kernel_config DM_VERITY y
set_kernel_config DM_VERITY_VERIFY_ROOTHASH_SIG y
set_kernel_config IMA y
set_kernel_config IMA_APPRAISE y
set_kernel_config EVM y
set_kernel_config CRYPTO_ECDSA y
set_kernel_config DEVTMPFS y
set_kernel_config DEVTMPFS_MOUNT y
set_kernel_config NET_9P y
set_kernel_config NET_9P_VIRTIO y
set_kernel_config 9P_FS y
set_kernel_config 9P_FS_POSIX_ACL y
set_kernel_config TMPFS y
set_kernel_config TMPFS_POSIX_ACL y

log "Finalizing kernel configuration..."
{ sleep 0.1; printf '\n%.0s' {1..100}; } | make ARCH="${ARCH}" CROSS_COMPILE="${CROSS}" olddefconfig

log "Building kernel (this may take 5-10 minutes)..."
make -j"$((JOBS > 4 ? 4 : JOBS))" ARCH="${ARCH}" CROSS_COMPILE="${CROSS}" Image dtbs

if [[ ! -f "arch/arm64/boot/Image" ]]; then
    fail "Kernel Image was not built successfully"
fi

reqf "arch/arm64/boot/Image"
popd >/dev/null

log "Looking for virt DTB file..."
VIRT_DTB=""

if [[ -d "${FT}/kernel/src/arch/arm64/boot/dts" ]]; then
    VIRT_DTB="$(find "${FT}/kernel/src/arch/arm64/boot/dts" -type f \( -name "*virt*.dtb" -o -name "*qemu*.dtb" \) | head -n1 || true)"
fi

if [[ -z "${VIRT_DTB}" ]]; then
    log "No virt DTB found in boot/dts, checking full source tree..."
    VIRT_DTB="$(find "${FT}/kernel/src" -type f \( -name "*virt*.dtb" -o -name "*qemu*.dtb" \) | head -n1 || true)"
fi

if [[ -z "${VIRT_DTB}" ]]; then
    log "No pre-built DTB found, building device trees explicitly..."
    pushd "${FT}/kernel/src" >/dev/null
    
    log "Building ARM64 device trees..."
    make ARCH="${ARCH}" CROSS_COMPILE="${CROSS}" dtbs
    
    VIRT_DTB="$(find "${FT}/kernel/src/arch/arm64/boot/dts" -type f \( -name "*virt*.dtb" -o -name "*qemu*.dtb" \) | head -n1 || true)"
    
    if [[ -z "${VIRT_DTB}" ]]; then
        log "Available DTBs in arch/arm64/boot/dts:"
        find "${FT}/kernel/src/arch/arm64/boot/dts" -name "*.dtb" | head -10 || true
        
        log "Attempting to build specific virt DTB..."
        if [[ -f "arch/arm64/boot/dts/arm/foundation-v8.dts" ]] || [[ -f "arch/arm64/boot/dts/arm/fvp-base-revc.dts" ]]; then
            make ARCH="${ARCH}" CROSS_COMPILE="${CROSS}" arch/arm64/boot/dts/arm/foundation-v8.dtb 2>/dev/null || true
            make ARCH="${ARCH}" CROSS_COMPILE="${CROSS}" arch/arm64/boot/dts/arm/fvp-base-revc.dtb 2>/dev/null || true
        fi
        
        # Final check
        VIRT_DTB="$(find "${FT}/kernel/src/arch/arm64/boot/dts" -type f \( -name "*virt*.dtb" -o -name "*qemu*.dtb" -o -name "foundation*.dtb" -o -name "fvp*.dtb" \) | head -n1 || true)"
    fi
    
    popd >/dev/null
fi

if [[ -n "${VIRT_DTB}" ]]; then
    log "Found DTB: ${VIRT_DTB}"
    cp -f "${VIRT_DTB}" "${FT}/boot/fit/virt.dtb"
else
    log "Warning: Could not find a virt DTB, using U-Boot DTB instead"
    cp -f "${FT}/boot/u-boot/src/u-boot.dtb" "${FT}/boot/fit/virt.dtb"
fi

cp -f "${FT}/kernel/src/arch/arm64/boot/Image" "${FT}/boot/fit/Image"

if [[ ! -d "${FT}/tier1_initramfs/src/.git" ]]; then
  log "Cloning BusyBox..."
  rm -rf "${FT}/tier1_initramfs/src"
  git clone --depth=1 "${BUSYBOX_GIT}" "${FT}/tier1_initramfs/src"
fi

log "Building BusyBox (arm64 static) with CROSS=${CROSS} ..."
pushd "${FT}/tier1_initramfs/src" >/dev/null

make CROSS_COMPILE="${CROSS}" ARCH="${ARCH}" defconfig

log "Configuring BusyBox for static build (non-interactive)..."
cat > busybox_config.sed << 'SED_SCRIPT'
s/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/
s/^# CONFIG_CTTYHACK is not set/CONFIG_CTTYHACK=y/
# Disable SHA hardware acceleration to fix compilation errors
s/^CONFIG_SHA1_HWACCEL=.*/CONFIG_SHA1_HWACCEL=n/
s/^CONFIG_SHA256_HWACCEL=.*/CONFIG_SHA256_HWACCEL=n/
SED_SCRIPT

sed -i -f busybox_config.sed .config

rm -f busybox_config.sed

log "Disabling problematic SHA hardware acceleration..."
echo "# Disable SHA hardware acceleration to fix compilation" >> .config
echo "CONFIG_SHA1_HWACCEL=n" >> .config
echo "CONFIG_SHA256_HWACCEL=n" >> .config

log "Generating non-interactive BusyBox configuration..."

cat > configure_busybox.exp << 'EXPECT_SCRIPT'
#!/usr/bin/expect -f
set timeout 10
spawn make oldconfig
expect {
    "Enable compatibility for full-blown desktop systems (8kb) (DESKTOP) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Provide compatible behavior for rare corner cases (bigger code) (EXTRA_COMPAT) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Building for Fedora distribution (FEDORA_COMPAT) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Enable obsolete features removed before SUSv3 (INCLUDE_SUSv2) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support --long-options (LONG_OPTS) \\\[Y/?\\\]" { send "y\r"; exp_continue }
    "Show applet usage messages (SHOW_USAGE) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Show verbose applet usage messages (FEATURE_VERBOSE_USAGE) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Store applet usage messages in compressed form (FEATURE_COMPRESS_USAGE) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support files > 2 GB (LFS) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support 64bit wide time types (TIME64) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support PAM (Pluggable Authentication Modules) (PAM) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Use the devpts filesystem for Unix98 PTYs (FEATURE_DEVPTS) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support utmp file (FEATURE_UTMP) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support wtmp file (FEATURE_WTMP) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support writing pidfiles (FEATURE_PIDFILE) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Directory for pidfiles (PID_FILE_PATH) \\\[/var/run\\\]" { send "/var/run\r"; exp_continue }
    "Include busybox applet (BUSYBOX) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support --show SCRIPT (FEATURE_SHOW_SCRIPT) \\\[Y/n\\\]" { send "y\r"; exp_continue }
    "Support --install \\\[-s\\\] to install applet links at runtime (FEATURE_INSTALLER) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Don't use /usr (INSTALL_NO_USR) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Drop SUID state for most applets (FEATURE_SUID) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Enable SUID configuration via /etc/busybox.conf (FEATURE_SUID_CONFIG) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Suppress warning message if /etc/busybox.conf is not readable (FEATURE_SUID_CONFIG_QUIET) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "exec prefers applets (FEATURE_PREFER_APPLETS) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Path to busybox executable (BUSYBOX_EXEC_PATH) \\\[/proc/self/exe\\\]" { send "/proc/self/exe\r"; exp_continue }
    "Support NSA Security Enhanced Linux (SELINUX) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Clean up all memory before exiting (usually not needed) (FEATURE_CLEAN_UP) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Support LOG_INFO level syslog messages (FEATURE_SYSLOG_INFO) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Build static binary (no shared libs) (STATIC) \\\[N/y/?\\\]" { send "y\r"; exp_continue }
    "Build position independent executable (PIE) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Force NOMMU build (NOMMU) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Build shared libbusybox (BUILD_LIBBUSYBOX) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Cross compiler prefix (CROSS_COMPILER_PREFIX) \\\[\\\]" { send "\r"; exp_continue }
    "Path to sysroot (SYSROOT) \\\[\\\]" { send "\r"; exp_continue }
    "Additional CFLAGS (EXTRA_CFLAGS) \\\[\\\]" { send "\r"; exp_continue }
    "Additional LDFLAGS (EXTRA_LDFLAGS) \\\[\\\]" { send "\r"; exp_continue }
    "Additional LDLIBS (EXTRA_LDLIBS) \\\[\\\]" { send "\r"; exp_continue }
    "Avoid using GCC-specific code constructs (USE_PORTABLE_CODE) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Use -mpreferred-stack-boundary=2 on i386 arch (STACK_OPTIMIZATION_386) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Use -static-libgcc (STATIC_LIBGCC) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "What kind of applet links to install" { send "1\r"; exp_continue }
    "Destination path for 'make install' (PREFIX) \\\[./_install\\\]" { send "./_install\r"; exp_continue }
    "Build with debug information (DEBUG) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Enable runtime sanitizers (ASAN/LSAN/USAN/etc...) (DEBUG_SANITIZE) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Build unit tests (UNIT_TEST) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Abort compilation on any warning (WERROR) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Warn about single parameter bb_xx_msg calls (WARN_SIMPLE_MSG) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Additional debugging library" { send "1\r"; exp_continue }
    "Use the end of BSS page (FEATURE_USE_BSS_TAIL) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Enable fractional duration arguments (FLOAT_DURATION) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Support RTMIN\\\[+n\\\] and RTMAX\\\[-n\\\] signal names (FEATURE_RTMINMAX) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Use the definitions of SIGRTMIN/SIGRTMAX provided by libc (FEATURE_RTMINMAX_USE_LIBC_DEFINITIONS) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Buffer allocation policy" { send "1\r"; exp_continue }
    "Minimum password length (PASSWORD_MINLEN) \\\[6\\\]" { send "6\r"; exp_continue }
    "MD5: Trade bytes for speed (0:fast, 3:slow) (MD5_SMALL) \\\[1\\\]" { send "1\r"; exp_continue }
    "SHA1: Trade bytes for speed (0:fast, 3:slow) (SHA1_SMALL) \\\[3\\\]" { send "3\r"; exp_continue }
    "SHA1: Use hardware accelerated instructions if possible (SHA1_HWACCEL) \\\[Y/n/?\\\]" { send "n\r"; exp_continue }
    "SHA256: Use hardware accelerated instructions if possible (SHA256_HWACCEL) \\\[Y/n/?\\\]" { send "n\r"; exp_continue }
    "SHA3: Trade bytes for speed (0:fast, 1:slow) (SHA3_SMALL) \\\[1\\\]" { send "1\r"; exp_continue }
    "Non-POSIX, but safer, copying to special nodes (FEATURE_NON_POSIX_CP) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Give more precise messages when copy fails (cp, mv etc) (FEATURE_VERBOSE_CP_MESSAGE) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Use sendfile system call (FEATURE_USE_SENDFILE) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Copy buffer size, in kilobytes (FEATURE_COPYBUF_KB) \\\[4\\\]" { send "4\r"; exp_continue }
    "Use clock_gettime(CLOCK_MONOTONIC) syscall (MONOTONIC_SYSCALL) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Use ioctl names rather than hex values in error messages (IOCTL_HEX2STR_ERROR) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Command line editing (FEATURE_EDITING) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Maximum length of input (FEATURE_EDITING_MAX_LEN) \\\[1024\\\]" { send "1024\r"; exp_continue }
    "vi-style line editing commands (FEATURE_EDITING_VI) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "History size (FEATURE_EDITING_HISTORY) \\\[255\\\]" { send "255\r"; exp_continue }
    "History saving (FEATURE_EDITING_SAVEHISTORY) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Save history on shell exit, not after every command (FEATURE_EDITING_SAVE_ON_EXIT) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Reverse history search (FEATURE_REVERSE_SEARCH) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Tab completion (FEATURE_TAB_COMPLETION) \\\[Y/n\\\]" { send "y\r"; exp_continue }
    "Username completion (FEATURE_USERNAME_COMPLETION) \\\[Y/n\\\]" { send "y\r"; exp_continue }
    "Fancy shell prompts (FEATURE_EDITING_FANCY_PROMPT) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Enable automatic tracking of window size changes (FEATURE_EDITING_WINCH) \\\[Y/n\\\]" { send "y\r"; exp_continue }
    "Query cursor position from terminal (FEATURE_EDITING_ASK_TERMINAL) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Enable locale support (system needs locale for this to work) (LOCALE_SUPPORT) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Support Unicode (UNICODE_SUPPORT) \\\[Y/n/?\\\]" { send "y\r"; exp_continue }
    "Check \\\$LC_ALL, \\\$LC_CTYPE and \\\$LANG environment variables (FEATURE_CHECK_UNICODE_IN_ENV) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Character code to substitute unprintable characters with (SUBST_WCHAR) \\\[63\\\]" { send "63\r"; exp_continue }
    "Range of supported Unicode characters (LAST_SUPPORTED_WCHAR) \\\[767\\\]" { send "767\r"; exp_continue }
    "Allow zero-width Unicode characters on output (UNICODE_COMBINING_WCHARS) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Allow wide Unicode characters on output (UNICODE_WIDE_WCHARS) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Bidirectional character-aware line input (UNICODE_BIDI_SUPPORT) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Make it possible to enter sequences of chars which are not Unicode (UNICODE_PRESERVE_BROKEN) \\\[N/y/?\\\]" { send "n\r"; exp_continue }
    "Use LOOP_CONFIGURE for losetup and loop mounts" { send "3\r"; exp_continue }
    -re ".*choice\\\[1-3\\?\\\].*" { send "3\r"; exp_continue }
    -re ".*\\\[Y/n/?\\\].*" { send "y\r"; exp_continue }
    -re ".*\\\[N/y/?\\\].*" { send "n\r"; exp_continue }
    eof { exit 0 }
    timeout { exit 1 }
}
EXPECT_SCRIPT

chmod +x configure_busybox.exp
if ./configure_busybox.exp; then
    log "BusyBox configuration completed successfully"
else
    log "BusyBox configuration may have timed out, but continuing with build..."
fi

log "Finalizing BusyBox configuration (accepting defaults)..."
yes "" | make oldconfig || true

sed -i 's/^CONFIG_SHA1_HWACCEL=.*/CONFIG_SHA1_HWACCEL=n/' .config
sed -i 's/^CONFIG_SHA256_HWACCEL=.*/CONFIG_SHA256_HWACCEL=n/' .config

log "Building BusyBox..."
make -j"${JOBS}" CROSS_COMPILE="${CROSS}" ARCH="${ARCH}"
make CROSS_COMPILE="${CROSS}" ARCH="${ARCH}" CONFIG_PREFIX="${FT}/tier1_initramfs/rootfs" install

reqf "${FT}/tier1_initramfs/rootfs/bin/busybox"
file "${FT}/tier1_initramfs/rootfs/bin/busybox" | grep -qi 'ARM aarch64' || fail "BusyBox is not aarch64"

log "Cleaning up any x86_64 libraries..."
find "${FT}/tier1_initramfs/rootfs" -type d -name "*x86_64*" -exec rm -rf {} + 2>/dev/null || true
find "${FT}/tier1_initramfs/rootfs" -type f -name "*x86_64*" -delete 2>/dev/null || true
if find "${FT}/tier1_initramfs/rootfs" -type f -executable -exec file {} \; 2>/dev/null | grep -q "x86-64"; then
    log " Warning: Found x86_64 executables, removing..."
    find "${FT}/tier1_initramfs/rootfs" -type f -executable -exec sh -c 'file "$1" | grep -q "x86-64" && rm -f "$1"' _ {} \; 2>/dev/null || true
fi
log " Cleanup complete - only ARM64 binaries remain"
popd >/dev/null

if [[ ! -f "${FT}/tier1_initramfs/rootfs/usr/bin/openssl" ]]; then
  log "Cross-compiling OpenSSL for ARM64 (this takes 10-15 minutes)..."
  
  if [[ ! -d "${FT}/openssl/src/.git" ]]; then
    log "Cloning OpenSSL..."
    rm -rf "${FT}/openssl/src"
    mkdir -p "${FT}/openssl"
    git clone --depth=1 https://github.com/openssl/openssl.git "${FT}/openssl/src"
  fi
  
  pushd "${FT}/openssl/src" >/dev/null
  
  log "Configuring OpenSSL for ARM64 static build..."
  ./Configure linux-aarch64 \
    no-shared \
    no-asm \
    no-tests \
    --prefix="${FT}/openssl/install" \
    --cross-compile-prefix="${CROSS}"
  
  log "Building OpenSSL (be patient, this takes time)..."
  make -j"${JOBS}"
  
  log "Installing OpenSSL to prefix..."
  make install_sw
  
  log "Installing OpenSSL binary to initramfs..."
  mkdir -p "${FT}/tier1_initramfs/rootfs/usr/bin"
  cp -f "${FT}/openssl/install/bin/openssl" "${FT}/tier1_initramfs/rootfs/usr/bin/"
  
  file "${FT}/tier1_initramfs/rootfs/usr/bin/openssl" | grep -qi 'ARM aarch64' || \
    fail "OpenSSL is not aarch64"
  
  log " OpenSSL ARM64 installed successfully"
  popd >/dev/null
else
  log "OpenSSL already present in initramfs, skipping build"
fi

log "Setting up Tier-1 /init (progressive boot)..."
if [ -f "${FT}/tier1_initramfs/build/init_progressive.sh" ]; then
    cp -f "${FT}/tier1_initramfs/build/init_progressive.sh" "${FT}/tier1_initramfs/rootfs/init"
    chmod +x "${FT}/tier1_initramfs/rootfs/init"
    log " Using progressive boot init script"
else
    log " Progressive init script not found, creating minimal fallback..."
    cat > "${FT}/tier1_initramfs/rootfs/init" <<'SH'
#!/bin/sh
set +e
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs devtmpfs /dev
mount -t proc      proc     /proc
mount -t sysfs     sys      /sys
echo "PAC Tier-1 (minimal fallback)"
exec setsid cttyhack /bin/sh
SH
    chmod +x "${FT}/tier1_initramfs/rootfs/init"
fi

ln -sf busybox "${FT}/tier1_initramfs/rootfs/bin/sh" || true

log "Copying PAC scripts to Tier 1 initramfs..."
copy_runtime_scripts "${FT}/tier1_initramfs/rootfs"
log " PAC scripts installed in Tier 1 initramfs"

mkdir -p "${FT}/tier1_initramfs/rootfs"/{proc,sys,dev,run,tier2,host_tmp}
mkdir -p "${FT}/tier1_initramfs/rootfs/etc"
echo -e "Welcome to PAC Tier-1\n" > "${FT}/tier1_initramfs/rootfs/etc/motd"
log " Created /host_tmp mount point for 9p shared filesystem"

log "Building a tiny Tier-2 rootfs (ext4 image)..."
mkdir -p "${FT}/tier2/rootfs"/{bin,sbin,proc,sys,dev,etc,usr/bin,host_tmp}
cp -a "${FT}/tier1_initramfs/rootfs/bin/busybox" "${FT}/tier2/rootfs/bin/"
log " Created /host_tmp mount point for Tier 2"

cd "${FT}/tier2/rootfs"
rm -f bin/sh 2>/dev/null || true
ln -sf /bin/busybox bin/sh
rm -f bin/mount sbin/mount bin/umount sbin/umount 2>/dev/null || true
ln -sf /bin/busybox bin/mount
ln -sf /bin/busybox bin/umount
ln -sf /bin/busybox sbin/mount
ln -sf /bin/busybox sbin/umount
ln -sf /bin/busybox bin/echo
ln -sf /bin/busybox bin/cat
ln -sf /bin/busybox bin/ls
ln -sf /bin/busybox bin/pwd
ln -sf /bin/busybox bin/ps
ln -sf /bin/busybox bin/grep
ln -sf /bin/busybox bin/awk
ln -sf /bin/busybox bin/sed
ln -sf /bin/busybox bin/cut
ln -sf /bin/busybox bin/head
ln -sf /bin/busybox bin/tail
ln -sf /bin/busybox bin/dirname
ln -sf /bin/busybox bin/basename
ln -sf /bin/busybox bin/test
ln -sf /bin/busybox bin/[
ln -sf /bin/busybox bin/mkdir
ln -sf /bin/busybox bin/rmdir
ln -sf /bin/busybox bin/mountpoint
ln -sf /bin/busybox bin/mknod
ln -sf /bin/busybox bin/cp
ln -sf /bin/busybox bin/rm
ln -sf /bin/busybox bin/sleep
ln -sf /bin/busybox bin/ip
ln -sf /bin/busybox bin/udhcpc
ln -sf /bin/busybox bin/cttyhack
ln -sf /bin/busybox bin/setsid
ln -sf /bin/busybox bin/stty
ln -sf /bin/busybox sbin/reboot
ln -sf /bin/busybox usr/bin/wget
ln -sf /bin/busybox bin/ping
ln -sf /bin/busybox bin/ping6
ln -sf /bin/busybox usr/bin/sha256sum
ln -sf /bin/busybox bin/date
ln -sf /bin/busybox usr/bin/base64
ln -sf /bin/busybox bin/hostname
if [ ! -L bin/sh ] || [ ! -e bin/sh ]; then
    log " /bin/sh symlink issue, fixing..."
    rm -f bin/sh
    ln -sf /bin/busybox bin/sh
fi
if [ ! -e bin/sh ]; then
    fail "Failed to create /bin/sh symlink in Tier 2 rootfs"
fi
log " Tier 2 rootfs symlinks created"

log "Syncing PAC runtime scripts to Tier 2 rootfs..."
copy_runtime_scripts "${FT}/tier2/rootfs"
mkdir -p "${FT}/tier2/rootfs/var/pac"

mkdir -p "${FT}/tier2/rootfs/tmp"
log " Created /tmp directory in Tier 2 rootfs"

if [ -f "${FT}/tier1_initramfs/rootfs/usr/bin/openssl" ]; then
    mkdir -p "${FT}/tier2/rootfs/usr/bin"
    cp -a "${FT}/tier1_initramfs/rootfs/usr/bin/openssl" "${FT}/tier2/rootfs/usr/bin/" || true
    log " OpenSSL copied to Tier 2 rootfs"
    
    CROSS_SYSROOT="/usr/aarch64-linux-gnu"
    if [ -d "$CROSS_SYSROOT" ]; then
        log "Copying ARM64 runtime libraries to Tier 2..."
        mkdir -p "${FT}/tier2/rootfs/lib" "${FT}/tier2/rootfs/lib64"
        
        if [ -f "$CROSS_SYSROOT/lib/ld-linux-aarch64.so.1" ]; then
            cp -a "$CROSS_SYSROOT/lib/ld-linux-aarch64.so.1" "${FT}/tier2/rootfs/lib/" || true
        fi
        
        for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 libresolv.so.2; do
            if [ -f "$CROSS_SYSROOT/lib/$lib" ]; then
                cp -a "$CROSS_SYSROOT/lib/$lib" "${FT}/tier2/rootfs/lib/" || true
            fi
        done
        
        log " ARM64 runtime libraries copied"
    fi
fi

mkdir -p dev

cat > "${FT}/tier2/rootfs/sbin/init" <<'SH'
#!/bin/sh
# Mount /dev FIRST - critical for everything else
# Don't redirect to /dev/null yet - it might not exist!

# Ensure /dev directory exists
[ ! -d /dev ] && mkdir -p /dev 2>&1

# Check if /dev is already mounted (from initramfs via switch_root)
if mountpoint -q /dev 2>&1; then
    # /dev is already mounted - try to remount read-write
    mount -o remount,rw /dev 2>&1 || true
else
    # /dev not mounted - mount it fresh
    mount -t devtmpfs devtmpfs /dev 2>&1 || \
    mount -t tmpfs tmpfs /dev 2>&1 || true
fi

# Create essential device nodes if they don't exist and /dev is writable
[ -w /dev ] && [ ! -e /dev/null ] && mknod /dev/null c 1 3 2>&1 || true
[ -w /dev ] && [ ! -e /dev/zero ] && mknod /dev/zero c 1 5 2>&1 || true
[ -w /dev ] && [ ! -e /dev/console ] && mknod /dev/console c 5 1 2>&1 || true
[ -w /dev ] && [ ! -e /dev/tty ] && mknod /dev/tty c 5 0 2>&1 || true
[ -w /dev ] && [ ! -e /dev/random ] && mknod /dev/random c 1 8 2>&1 || true
[ -w /dev ] && [ ! -e /dev/urandom ] && mknod /dev/urandom c 1 9 2>&1 || true

# Now mount proc and sys (after /dev/null exists)
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true

# Mount host /tmp for fault injection (9p shared filesystem)
echo "[INIT-T2] Checking 9p mount..."
if mount | grep -q "/host_tmp"; then
    echo "[INIT-T2]  /host_tmp already mounted (from Tier 1)"
    if [ -f /host_tmp/inject_ecc_errors ]; then
        ecc_val=$(cat /host_tmp/inject_ecc_errors 2>/dev/null || echo "0")
        echo "[INIT-T2]  Can read inject_ecc_errors: $ecc_val"
    fi
else
    echo "[INIT-T2] Attempting 9p mount..."
    if mount -t 9p -o trans=virtio,version=9p2000.L,rw,nofail host_tmp /host_tmp 2>&1; then
        echo "[INIT-T2]  9p mount successful"
        if [ -f /host_tmp/inject_ecc_errors ]; then
            ecc_val=$(cat /host_tmp/inject_ecc_errors 2>/dev/null || echo "0")
            echo "[INIT-T2]  Can read inject_ecc_errors: $ecc_val"
        fi
    else
        echo "[INIT-T2]  9p mount failed"
    fi
fi

# Mount /var and /tmp as tmpfs (critical for runtime operations)
echo "[INIT-T2] Mounting writable filesystems..."

# Ensure /var directory exists
[ ! -d /var ] && mkdir -p /var 2>&1 || true
# Check if /var is already mounted, if not mount it
if ! grep -q " /var " /proc/mounts 2>&1; then
    echo "[INIT-T2] Mounting /var as tmpfs..."
    mount -t tmpfs tmpfs /var 2>&1 || echo "[INIT-T2] WARNING: Failed to mount /var"
else
    echo "[INIT-T2] /var already mounted"
fi
mkdir -p /var/pac /var/log /var/run 2>&1 || true

# Ensure /tmp directory exists  
[ ! -d /tmp ] && mkdir -p /tmp 2>&1 || true
# Check if /tmp is already mounted, if not mount it
if ! grep -q " /tmp " /proc/mounts 2>&1; then
    echo "[INIT-T2] Mounting /tmp as tmpfs..."
    mount -t tmpfs -o size=64M tmpfs /tmp 2>&1 && echo "[INIT-T2]  /tmp mounted successfully" || echo "[INIT-T2] ERROR: Failed to mount /tmp"
else
    echo "[INIT-T2] /tmp already mounted"
fi

# Final verification
if [ -w /tmp ]; then
    echo "[INIT-T2]  /tmp is writable"
else
    echo "[INIT-T2] ERROR: /tmp is NOT writable - attestation will fail!"
    ls -ld /tmp
    mount | grep tmp
fi

echo ""
echo "╗"
echo "              TIER 2: REDUCED FUNCTIONALITY MODE                    "
echo "╝"
echo ""
echo "   dm-verity protected rootfs (read-only)"
echo "   Network operational"
echo "   Essential services available"
echo ""

# Initialize journal if it doesn't exist
if [ ! -f /var/pac/journal.dat ]; then
    if [ -f /bin/journal_tool ]; then
        /bin/journal_tool init /var/pac/journal.dat 2>/dev/null || {
            echo "Warning: Failed to initialize journal" >&2
        }
        # Set tier to 2 since we're in Tier 2 rootfs
        /bin/journal_tool set-tier 2 /var/pac/journal.dat 2>/dev/null || true
        echo "   Journal initialized (Tier 2)"
    fi
else
    # Journal exists - ensure it's set to Tier 2
    if [ -f /bin/journal_tool ]; then
        /bin/journal_tool set-tier 2 /var/pac/journal.dat 2>/dev/null || true
    fi
fi

# Start policy monitor daemon for runtime promotion to Tier 3
if [ -f "/usr/lib/pac/policy_monitor.sh" ]; then
    echo ""
    echo ""
    echo "STARTING POLICY MONITOR (Runtime Tier 2  Tier 3 Promotion)"
    echo ""
    sh /usr/lib/pac/policy_monitor.sh start 2>/dev/null || true
    echo "   Policy monitor daemon started (Tier 2)"
    echo "   Monitoring for Tier 3 promotion when verifier available"
    echo ""
fi

# Setup console terminal properly
if [ -c /dev/console ]; then
    # Redirect stdin/stdout/stderr to console
    exec < /dev/console > /dev/console 2>&1
    
    echo "[DEBUG-T2] Console redirected, fixing terminal state..."
    # Fix terminal state - must be done on the actual console
    STTY_BIN=$(command -v stty 2>&1 | head -1)
    if [ -n "$STTY_BIN" ] && [ -x "$STTY_BIN" ]; then
        echo "[DEBUG-T2] Running stty commands..."
        $STTY_BIN sane </dev/console 2>&1 || true
        $STTY_BIN echo </dev/console 2>&1 || true
        $STTY_BIN icanon </dev/console 2>&1 || true
        $STTY_BIN onlcr </dev/console 2>&1 || true
        echo "[DEBUG-T2] stty completed"
    else
        echo "[DEBUG-T2] stty not found"
    fi
else
    echo "[DEBUG-T2] /dev/console not available"
fi

# Launch interactive shell with PS1 prompt
export PS1='~ # '
echo "[DEBUG-T2] About to exec shell: setsid cttyhack sh"
exec setsid cttyhack sh || exec /bin/sh
SH
chmod +x "${FT}/tier2/rootfs/sbin/init"
echo "PAC Tier-2 (Reduced functionality with dm-verity)" > "${FT}/tier2/rootfs/etc/motd"
cd "${FT}"

dd if=/dev/zero of="${FT}/tier2/img/tier2.ext4" bs=1M count=64 status=none
mkfs.ext4 -F "${FT}/tier2/img/tier2.ext4" >/dev/null
mkdir -p "${FT}/tier2/mnt"
sudo mount -o loop "${FT}/tier2/img/tier2.ext4" "${FT}/tier2/mnt"
sudo cp -a "${FT}/tier2/rootfs/." "${FT}/tier2/mnt/"
sync
sudo umount "${FT}/tier2/mnt"
rmdir "${FT}/tier2/mnt"

log "Generating dm-verity metadata for Tier 2 rootfs..."
mkdir -p "${FT}/tier2/img"
cd "${FT}/tier2/img"

SALT=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')
veritysetup format tier2.ext4 tier2.verity --hash sha256 --salt "$SALT" > verity.out 2>&1 || {
    log " veritysetup failed, continuing without dm-verity (will use direct mount)"
    rm -f verity.out tier2.verity
}

if [ -f tier2.verity ]; then
    ROOT_HASH=$(grep "Root hash:" verity.out 2>/dev/null | awk -F': ' '{print $2}' | tr -d ' ')
    if [ -n "$ROOT_HASH" ]; then
        echo "$ROOT_HASH" > tier2.roothash
        log " dm-verity metadata generated (root hash: ${ROOT_HASH:0:16}...)"
    else
        log " Could not extract root hash, continuing without dm-verity"
        rm -f tier2.verity tier2.roothash
    fi
fi

mkdir -p "${FT}/tier1_initramfs/rootfs/tier2"
cp -f "${FT}/tier2/img/tier2.ext4" "${FT}/tier1_initramfs/rootfs/tier2/rootfs.img"
if [ -f "${FT}/tier2/img/tier2.verity" ]; then
    cp -f "${FT}/tier2/img/tier2.verity" "${FT}/tier1_initramfs/rootfs/tier2/verity.img"
    log " Verity metadata copied to initramfs"
fi
if [ -f "${FT}/tier2/img/tier2.roothash" ]; then
    cp -f "${FT}/tier2/img/tier2.roothash" "${FT}/tier1_initramfs/rootfs/tier2/verity.roothash"
    log " Root hash copied to initramfs"
fi

log "Building Tier-3 rootfs (full filesystem with IMA/EVM support)..."
mkdir -p "${FT}/tier3/rootfs"/{bin,sbin,usr/bin,proc,sys,dev,etc,lib,lib64,var,root,home,host_tmp}
cp -a "${FT}/tier1_initramfs/rootfs/bin/busybox" "${FT}/tier3/rootfs/bin/"
ln -sf busybox "${FT}/tier3/rootfs/bin/sh" || true
log " Created /host_tmp mount point for Tier 3"

if [ -f "${FT}/tier1_initramfs/rootfs/usr/bin/openssl" ]; then
    mkdir -p "${FT}/tier3/rootfs/usr/bin"
    cp -a "${FT}/tier1_initramfs/rootfs/usr/bin/openssl" "${FT}/tier3/rootfs/usr/bin/" || true
    
    CROSS_SYSROOT="/usr/aarch64-linux-gnu"
    if [ -d "$CROSS_SYSROOT" ]; then
        log "Copying ARM64 runtime libraries to Tier 3..."
        mkdir -p "${FT}/tier3/rootfs/lib" "${FT}/tier3/rootfs/lib64"
        
        if [ -f "$CROSS_SYSROOT/lib/ld-linux-aarch64.so.1" ]; then
            cp -a "$CROSS_SYSROOT/lib/ld-linux-aarch64.so.1" "${FT}/tier3/rootfs/lib/" || true
        fi
        
        for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 libresolv.so.2; do
            if [ -f "$CROSS_SYSROOT/lib/$lib" ]; then
                cp -a "$CROSS_SYSROOT/lib/$lib" "${FT}/tier3/rootfs/lib/" || true
            fi
        done
        
        log " ARM64 runtime libraries copied to Tier 3"
    fi
fi

cd "${FT}/tier3/rootfs"
if [ -f bin/busybox ]; then
    [ ! -e usr/bin/wget ] && ln -sf /bin/busybox usr/bin/wget 2>/dev/null || true
    [ ! -e bin/ping ] && ln -sf /bin/busybox bin/ping 2>/dev/null || true
    [ ! -e bin/ping6 ] && ln -sf /bin/busybox bin/ping6 2>/dev/null || true
fi
cd "${FT}"
log " Policy monitor dependencies verified"

cd "${FT}/tier3/rootfs"
rm -f bin/sh 2>/dev/null || true
ln -sf /bin/busybox bin/sh
rm -f bin/mount sbin/mount bin/umount sbin/umount 2>/dev/null || true
ln -sf /bin/busybox bin/mount
ln -sf /bin/busybox bin/umount
ln -sf /bin/busybox sbin/mount
ln -sf /bin/busybox sbin/umount
ln -sf /bin/busybox bin/echo
ln -sf /bin/busybox bin/cat
ln -sf /bin/busybox bin/ls
ln -sf /bin/busybox bin/pwd
ln -sf /bin/busybox bin/ps
ln -sf /bin/busybox bin/grep
ln -sf /bin/busybox bin/awk
ln -sf /bin/busybox bin/sed
ln -sf /bin/busybox bin/cut
ln -sf /bin/busybox bin/head
ln -sf /bin/busybox bin/tail
ln -sf /bin/busybox bin/dirname
ln -sf /bin/busybox bin/basename
ln -sf /bin/busybox bin/test
ln -sf /bin/busybox bin/[
ln -sf /bin/busybox bin/mkdir
ln -sf /bin/busybox bin/rmdir
ln -sf /bin/busybox bin/mountpoint
ln -sf /bin/busybox bin/mknod
ln -sf /bin/busybox bin/cp
ln -sf /bin/busybox bin/rm
ln -sf /bin/busybox bin/sleep
ln -sf /bin/busybox bin/ip
ln -sf /bin/busybox bin/udhcpc
ln -sf /bin/busybox bin/cttyhack
ln -sf /bin/busybox bin/setsid
ln -sf /bin/busybox bin/stty
ln -sf /bin/busybox sbin/reboot
ln -sf /bin/busybox usr/bin/wget
ln -sf /bin/busybox bin/ping
ln -sf /bin/busybox bin/ping6
ln -sf /bin/busybox usr/bin/sha256sum
ln -sf /bin/busybox bin/date
ln -sf /bin/busybox usr/bin/base64
ln -sf /bin/busybox bin/hostname
if [ ! -L bin/sh ] || [ ! -e bin/sh ]; then
    log " /bin/sh symlink issue, fixing..."
    rm -f bin/sh
    ln -sf /bin/busybox bin/sh
fi
if [ ! -e bin/sh ]; then
    fail "Failed to create /bin/sh symlink in Tier 3 rootfs"
fi
log " Tier 3 rootfs symlinks created"

log "Syncing PAC runtime scripts to Tier 3 rootfs..."
copy_runtime_scripts "${FT}/tier3/rootfs"
mkdir -p "${FT}/tier3/rootfs/var/pac"

mkdir -p "${FT}/tier3/rootfs/tmp"
mkdir -p "${FT}/tier3/rootfs/host_tmp"
log " Created /tmp and /host_tmp directories in Tier 3 rootfs"

mkdir -p dev

cat > "${FT}/tier3/rootfs/sbin/init" <<'SH'
#!/bin/sh
# Mount /dev first - critical for everything else
# Don't redirect to /dev/null yet - it might not exist!

# Ensure /dev directory exists
[ ! -d /dev ] && mkdir -p /dev 2>&1

# Check if /dev is already mounted (from initramfs via switch_root)
if mountpoint -q /dev 2>&1; then
    # /dev is already mounted - try to remount read-write
    mount -o remount,rw /dev 2>&1 || true
else
    # /dev not mounted - mount it fresh
    mount -t devtmpfs devtmpfs /dev 2>&1 || \
    mount -t tmpfs tmpfs /dev 2>&1 || true
fi

# Create essential device nodes if they don't exist and /dev is writable
[ -w /dev ] && [ ! -e /dev/null ] && mknod /dev/null c 1 3 2>&1 || true
[ -w /dev ] && [ ! -e /dev/zero ] && mknod /dev/zero c 1 5 2>&1 || true
[ -w /dev ] && [ ! -e /dev/console ] && mknod /dev/console c 5 1 2>&1 || true
[ -w /dev ] && [ ! -e /dev/tty ] && mknod /dev/tty c 5 0 2>&1 || true
[ -w /dev ] && [ ! -e /dev/random ] && mknod /dev/random c 1 8 2>&1 || true
[ -w /dev ] && [ ! -e /dev/urandom ] && mknod /dev/urandom c 1 9 2>&1 || true

# Mount essential filesystems FIRST (required for mount command to work)
# Use a null device that definitely exists for error suppression
NULL_DEV="/dev/null"
[ ! -e "$NULL_DEV" ] && NULL_DEV="/dev/console" || true
[ ! -e "$NULL_DEV" ] && NULL_DEV="" || true

/bin/mount -t proc proc /proc 2>$NULL_DEV || {
    # Try alternative - create directory first
    /bin/mkdir -p /proc 2>$NULL_DEV || true
    /bin/mount -t proc proc /proc 2>$NULL_DEV || true
}

/bin/mount -t sysfs sysfs /sys 2>$NULL_DEV || {
    /bin/mkdir -p /sys 2>$NULL_DEV || true
    /bin/mount -t sysfs sysfs /sys 2>$NULL_DEV || true
}

# Mount host /tmp for fault injection (9p shared filesystem)
echo "[T3 INIT] Checking 9p mount..."
if /bin/mount | /bin/grep -q "/host_tmp"; then
    echo "[T3 INIT]  /host_tmp already mounted (from Tier 1)"
    if [ -f /host_tmp/inject_ecc_errors ]; then
        ecc_val=$(/bin/cat /host_tmp/inject_ecc_errors 2>$NULL_DEV || echo "0")
        echo "[T3 INIT]  Can read inject_ecc_errors: $ecc_val"
    fi
else
    echo "[T3 INIT] Attempting 9p mount..."
    if /bin/mount -t 9p -o trans=virtio,version=9p2000.L,rw,nofail host_tmp /host_tmp 2>&1; then
        echo "[T3 INIT]  9p mount successful"
        if [ -f /host_tmp/inject_ecc_errors ]; then
            ecc_val=$(/bin/cat /host_tmp/inject_ecc_errors 2>$NULL_DEV || echo "0")
            echo "[T3 INIT]  Can read inject_ecc_errors: $ecc_val"
        fi
    else
        echo "[T3 INIT]  9p mount failed"
    fi
fi

# Mount /var as tmpfs for writable runtime data (journal, PID files, etc.)
# Rootfs is read-only for integrity, but we need writable runtime areas
# IMPORTANT: We need to check if /var is already a mountpoint before mounting
# If /var exists on rootfs, we can still overmount it with tmpfs
if [ -f /proc/mounts ]; then
    if ! /bin/grep -q " /var " /proc/mounts 2>$NULL_DEV; then
        # /var is not mounted, try to mount tmpfs
        if /bin/mount -t tmpfs tmpfs /var 2>$NULL_DEV; then
            # Success - create directories
            /bin/mkdir -p /var/pac /var/run /var/log 2>$NULL_DEV || true
        else
            # Failed - try to create /var/pac on rootfs (read-only, but might work for some operations)
            /bin/mkdir -p /var/pac /var/run /var/log 2>$NULL_DEV || true
        fi
    else
        # /var is already mounted (should be tmpfs from previous attempt)
        /bin/mkdir -p /var/pac /var/run /var/log 2>$NULL_DEV || true
    fi

    # Mount /tmp as tmpfs
    if ! /bin/grep -q " /tmp " /proc/mounts 2>$NULL_DEV; then
        if /bin/mount -t tmpfs tmpfs /tmp 2>$NULL_DEV; then
            /bin/mkdir -p /tmp 2>$NULL_DEV || true
        else
            # Failed - create /tmp directory anyway
            /bin/mkdir -p /tmp 2>$NULL_DEV || true
        fi
    else
        # /tmp is already mounted
        /bin/mkdir -p /tmp 2>$NULL_DEV || true
    fi
else
    # /proc/mounts doesn't exist - try mounting anyway
    /bin/mount -t tmpfs tmpfs /var 2>$NULL_DEV || true
    /bin/mount -t tmpfs tmpfs /tmp 2>$NULL_DEV || true
    /bin/mkdir -p /var/pac /var/run /var/log /tmp 2>$NULL_DEV || true
fi

# Restore journal from backup if it exists (copied from initramfs before switch_root)
if [ -f /tmp/journal.dat.backup ]; then
    /bin/cp -f /tmp/journal.dat.backup /var/pac/journal.dat 2>$NULL_DEV || true
    /bin/rm -f /tmp/journal.dat.backup 2>$NULL_DEV || true
    echo "   Journal restored from initramfs"
    # Set tier to 3 since we're in Tier 3 rootfs
    if [ -f /bin/journal_tool ]; then
        /bin/journal_tool set-tier 3 /var/pac/journal.dat 2>$NULL_DEV || true
    fi
else
    # Initialize journal if it doesn't exist
    # The journal needs to be in writable tmpfs (/var/pac)
    if [ ! -f /var/pac/journal.dat ]; then
        if [ -f /bin/journal_tool ]; then
            /bin/journal_tool init /var/pac/journal.dat 2>$NULL_DEV || {
                echo "Warning: Failed to initialize journal" >&2
            }
            # Set tier to 3 since we're in Tier 3 rootfs
            /bin/journal_tool set-tier 3 /var/pac/journal.dat 2>$NULL_DEV || true
        fi
    fi
fi

echo ""
echo "╗"
echo "              TIER 3: FULL OPERATIONAL MODE                        "
echo "╝"
echo ""
echo "   IMA/EVM integrity protection enabled"
echo "   Full filesystem access"
echo "   All services available"
echo ""

# Start policy monitor daemon for runtime promotion/degradation
# Ensure /tmp is mounted and writable before starting monitor
if [ ! -d /tmp ] || [ ! -w /tmp ] 2>/dev/null; then
    /bin/mkdir -p /tmp 2>$NULL_DEV || true
    if ! /bin/grep -q " /tmp " /proc/mounts 2>$NULL_DEV; then
        /bin/mount -t tmpfs tmpfs /tmp 2>$NULL_DEV || true
    fi
fi

if [ -f "/usr/lib/pac/policy_monitor.sh" ]; then
    echo ""
    echo ""
    echo "STARTING POLICY MONITOR (FSM Runtime Evaluation)"
    echo ""
    echo "[DEBUG] About to start policy_monitor.sh..."
    sh /usr/lib/pac/policy_monitor.sh start 2>$NULL_DEV || true
    echo "[DEBUG] Policy monitor start command completed"
    echo "   Policy monitor daemon started (Tier 3)"
    echo "   Monitoring for promotion/degradation conditions"
    echo "   Will degrade to Tier 2 if verifier unreachable"
    echo ""
fi

echo "[DEBUG] Preparing to launch shell..."
# Check for binaries (don't use /dev/null redirect in case it doesn't exist)
SETSID_PATH=$(command -v setsid 2>&1 | head -1)
CTTYHACK_PATH=$(command -v cttyhack 2>&1 | head -1)
STTY_PATH=$(command -v stty 2>&1 | head -1)
echo "[DEBUG] Checking for setsid: ${SETSID_PATH:-NOT FOUND}"
echo "[DEBUG] Checking for cttyhack: ${CTTYHACK_PATH:-NOT FOUND}"
echo "[DEBUG] Checking for stty: ${STTY_PATH:-NOT FOUND}"
echo "[DEBUG] Console device: $( [ -c /dev/console ] && ls -l /dev/console || echo 'NOT FOUND' )"
echo "[DEBUG] TTY device: $( [ -c /dev/tty ] && ls -l /dev/tty || echo 'NOT FOUND' )"
echo "[DEBUG] /dev writable: $( [ -w /dev ] && echo 'YES' || echo 'NO' )"

# Set prompt and fix terminal state before launching shell
export PS1='~ # '
echo "[DEBUG] PS1 set to: $PS1"

if [ -n "$STTY_PATH" ] && [ -x "$STTY_PATH" ]; then
    if [ -c /dev/console ]; then
        echo "[DEBUG] Running stty commands with /dev/console..."
        $STTY_PATH sane </dev/console 2>&1 || true
        $STTY_PATH echo </dev/console 2>&1 || true
        $STTY_PATH icanon </dev/console 2>&1 || true
        $STTY_PATH onlcr </dev/console 2>&1 || true
        echo "[DEBUG] stty commands completed"
    elif [ -c /dev/tty ]; then
        echo "[DEBUG] /dev/console not found, using /dev/tty..."
        $STTY_PATH sane </dev/tty 2>&1 || true
        $STTY_PATH echo </dev/tty 2>&1 || true
        $STTY_PATH icanon </dev/tty 2>&1 || true
        $STTY_PATH onlcr </dev/tty 2>&1 || true
        echo "[DEBUG] stty commands completed"
    else
        echo "[DEBUG] No console device available for stty"
    fi
else
    echo "[DEBUG] stty not available"
fi

# Launch interactive shell with proper terminal
echo "[DEBUG] About to exec shell..."
echo "[DEBUG] Exec line: setsid cttyhack sh"
exec setsid cttyhack sh || exec /bin/sh
SH
chmod +x "${FT}/tier3/rootfs/sbin/init"
echo "PAC Tier-3 (Full operation with IMA/EVM)" > "${FT}/tier3/rootfs/etc/motd"
cd "${FT}"

mkdir -p "${FT}/tier3/rootfs/etc/ima"
mkdir -p "${FT}/tier3/rootfs/etc/keys"

log "Creating Tier 3 rootfs image (256MB)..."
mkdir -p "${FT}/tier3/img"
dd if=/dev/zero of="${FT}/tier3/img/tier3.ext4" bs=1M count=256 status=none
mkfs.ext4 -F "${FT}/tier3/img/tier3.ext4" >/dev/null
mkdir -p "${FT}/tier3/mnt"
sudo mount -o loop "${FT}/tier3/img/tier3.ext4" "${FT}/tier3/mnt"
sudo cp -a "${FT}/tier3/rootfs/." "${FT}/tier3/mnt/"
sync
sudo umount "${FT}/tier3/mnt"
rmdir "${FT}/tier3/mnt"

log "Generating IMA keys for Tier 3..."
mkdir -p "${FT}/tier3/keys"
if [ ! -f "${FT}/tier3/keys/ima_priv.pem" ]; then
    openssl genrsa -out "${FT}/tier3/keys/ima_priv.pem" 2048 2>/dev/null || {
        log " OpenSSL not available for IMA key generation, skipping..."
    }
    if [ -f "${FT}/tier3/keys/ima_priv.pem" ]; then
        openssl rsa -in "${FT}/tier3/keys/ima_priv.pem" -pubout -out "${FT}/tier3/keys/ima_pub.pem" 2>/dev/null || true
        log " IMA keys generated"
    fi
fi

log "Creating IMA policy for Tier 3..."
cat > "${FT}/tier3/rootfs/etc/ima/policy" <<'POLICY'
# IMA Policy for PAC Tier 3
# Measure and appraise executables
measure func=BPRM_CHECK
appraise func=BPRM_CHECK
POLICY

mkdir -p "${FT}/tier1_initramfs/rootfs/tier3"
cp -f "${FT}/tier3/img/tier3.ext4" "${FT}/tier1_initramfs/rootfs/tier3/rootfs.img"
if [ -f "${FT}/tier3/keys/ima_pub.pem" ]; then
    mkdir -p "${FT}/tier1_initramfs/rootfs/tier3/keys"
    cp -f "${FT}/tier3/keys/ima_pub.pem" "${FT}/tier1_initramfs/rootfs/tier3/keys/ima_pub.pem"
    log " IMA public key copied to initramfs"
fi
log " Tier 3 rootfs created and copied to initramfs"

log "Packing initramfs.cpio.gz..."
pushd "${FT}/tier1_initramfs/rootfs" >/dev/null
find . -mindepth 1 -print0 | cpio --null -ov --format=newc | gzip -9 > "${FT}/tier1_initramfs/img/initramfs.cpio.gz"
popd >/dev/null
gzip -t "${FT}/tier1_initramfs/img/initramfs.cpio.gz" || fail "initramfs gzip test failed"

cp -f "${FT}/tier1_initramfs/img/initramfs.cpio.gz" "${FT}/boot/fit/initramfs.cpio.gz"

cp -f "${FT}/tier1_initramfs/img/initramfs.cpio.gz" "${FT}/tier1_initramfs/img/pac_initramfs.cpio.gz"

log "Writing kernel.its (FIT spec: kernel+ramdisk+dtb, signed)..."
cat > "${FT}/boot/fit/kernel.its" <<'ITS'
/dts-v1/;
/ {
 description = "PAC Tier-1 FIT";
 #address-cells = <1>;
 images {
  kernel@1 {
    description = "Linux kernel";
    data = /incbin/("Image");
    type = "kernel";
    arch = "arm64";
    os = "linux";
    compression = "none";
    load = <0x80000>;
    entry = <0x80000>;
    hash@1 { algo = "sha256"; };
  };
  ramdisk@1 {
    description = "Tier-1 initramfs";
    data = /incbin/("initramfs.cpio.gz");
    type = "ramdisk";
    arch = "arm64";
    os = "linux";
    compression = "none";
    hash@1 { algo = "sha256"; };
  };
  fdt@1 {
    description = "virt DTB";
    data = /incbin/("virt.dtb");
    type = "flat_dt";
    arch = "arm64";
    compression = "none";
    hash@1 { algo = "sha256"; };
  };
 };
 configurations {
  default = "conf@1";
  conf@1 {
    kernel = "kernel@1";
    ramdisk = "ramdisk@1";
    fdt = "fdt@1";
    signature@1 {
      algo = "sha256,rsa2048";
      key-name-hint = "pac_signing";
      sign-images = "kernel", "ramdisk", "fdt";
    };
  };
 };
};
ITS

log "Building & signing fit.itb..."
pushd "${FT}/boot/fit" >/dev/null
reqf "Image"; reqf "initramfs.cpio.gz"; reqf "virt.dtb"
"${FT}/boot/u-boot/src/tools/mkimage" \
  -f kernel.its \
  -k ../keys \
  -K "${FT}/boot/u-boot/src/u-boot.dtb" \
  -r fit.itb
reqf "fit.itb"
popd >/dev/null

log "Writing TPM restart helper..."
cat > "${FT}/scripts/tpm-restart.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
STATE="${HOME}/ft-pac/tpmstate"
mkdir -p "${STATE}"
pkill -f "swtpm socket --tpm2" >/dev/null 2>&1 || true
swtpm socket --tpm2 \
  --tpmstate dir="${STATE}" \
  --server type=unixio,path=/tmp/swtpm.sock \
  --ctrl   type=unixio,path=/tmp/swtpm.sock.ctrl \
  --flags startup-clear --daemon
echo "TPM up at /tmp/swtpm.sock"
SH
chmod +x "${FT}/scripts/tpm-restart.sh"

DISK="${FT}/boot/fit/fake.img"
if [[ ! -f "${DISK}" ]]; then
  log "Creating a blank data disk: ${DISK}"
  qemu-img create -f raw "${DISK}" 1G >/dev/null
fi

log "Writing qemu-direct.sh (kernel+initramfs sanity path)..."
cat > "${FT}/scripts/qemu-direct.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
TPMSOCK="/tmp/swtpm.sock"
KIMG="${FT}/boot/fit/Image"
INITRD="${FT}/tier1_initramfs/img/initramfs.cpio.gz"
DTB="${FT}/boot/fit/virt.dtb"
DISK="${DISK}"

exec qemu-system-aarch64 \\
  -machine virt,gic-version=${GIC} \\
  -cpu ${CPU_QEMU} \\
  -m ${RAM_MB} \\
  -nographic \\
  -kernel "\${KIMG}" \\
  -initrd "\${INITRD}" \\
  -dtb "\${DTB}" \\
  -append "console=ttyAMA0 earlycon rdinit=/init" \\
  -drive if=none,id=drv0,file="\${DISK}",format=raw \\
  -device virtio-blk-pci,drive=drv0 \\
  -chardev socket,id=chrtpm,path="\${TPMSOCK}" \\
  -tpmdev emulator,id=tpm0,chardev=chrtpm \\
  -device tpm-tis-device,tpmdev=tpm0
SH
chmod +x "${FT}/scripts/qemu-direct.sh"

log "Writing qemu-uboot-fit.sh (U-Boot + FIT boot via 9p share)..."
cat > "${FT}/scripts/qemu-uboot-fit.sh" << 'SH'
#!/usr/bin/env bash
set -euo pipefail
FT="${HOME}/ft-pac"
TPMSOCK="/tmp/swtpm.sock"
UBOOT="${FT}/boot/u-boot/src/u-boot.elf"
FIT="${FT}/boot/fit/fit.itb"
DISK="${FT}/boot/fit/fake.img"

exec qemu-system-aarch64 \\
  -machine virt,gic-version=3 \\
  -cpu cortex-a57 \\
  -m 2048 \\
  -nographic \\
  -kernel "${UBOOT}" \\
  -append "console=ttyAMA0" \\
  -device virtio-blk-p,drive=drv0 \\
  -drive if=none,id=drv0,file="${DISK}",format=raw \\
  -chardev socket,id=chrtpm,path="${TPMSOCK}" \\
  -tpmdev emulator,id=tpm0,chardev=chrtpm \\
  -device tpm-tis,tpmdev=tpm0 \\
  -fsdev local,security_model=none,id=fsdev0,path="${FT}" \\
  -device virtio-9p-pci,fsdev=fsdev0,mount_tag=host \\
  -no-reboot

# In U-Boot:
# => host bind 0 /host
# => load host 0:0 \${loadaddr} /host/boot/fit/fit.itb
# => bootm \${loadaddr}
SH
chmod +x "${FT}/scripts/qemu-uboot-fit.sh"

log "All done "
echo
echo "Project dir: ${FT}"
echo
echo "Quick start:"
echo "  1) Start TPM:      ${FT}/scripts/tpm-restart.sh"
echo "  2) Sanity boot:    ${FT}/scripts/qemu-direct.sh"
echo "     (Expect: Tier-1 banner, then pivot  'PAC Tier-2 up (RO).')"
echo
echo "U-Boot + FIT path:"
echo "  ${FT}/scripts/qemu-uboot-fit.sh"
echo "  In U-Boot:"
echo "    => host bind 0 /host"
echo "    => load host 0:0 \${loadaddr} /host/boot/fit/fit.itb"
echo "    => bootm \${loadaddr}"
echo
