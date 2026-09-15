#!/usr/bin/bash
set -e

# Fedora release of the buildroot we're running in, so one script can serve
# several COPR chroots. `version`/the submodule pin remain the default; a
# release only needs version.NN + patches.NN when it diverges (e.g. f45 is on
# kernel 7.2 while f44 is still on 7.1).
FEDORA_RELEASE=$(rpm -E %fedora)
if [ -r "./version.${FEDORA_RELEASE}" ]; then
  KERNEL_VERSION=$(cat "./version.${FEDORA_RELEASE}")
else
  KERNEL_VERSION=$(cat ./version)
fi

if [ -r "./patches.${FEDORA_RELEASE}" ]; then
  PATCH_REF=$(cat "./patches.${FEDORA_RELEASE}")
  git -C linux-t2-patches fetch -q origin
  git -C linux-t2-patches switch -q --detach "$PATCH_REF"
fi

# The patch series declares the lowest kernel it applies to; refuse rather than
# emit a kernel with silently-dropped patches.
PATCH_KVER=$(cut -d= -f2 linux-t2-patches/version)
if [ "$(printf '%s\n%s\n' "$PATCH_KVER" "$KERNEL_VERSION" | rpmsort | tail -1)" != "$KERNEL_VERSION" ]; then
  echo "ERROR: patches target $PATCH_KVER but kernel is $KERNEL_VERSION" >&2
  exit 1
fi

cd "$sourcedir"
koji download-build --quiet --arch=src "kernel-$KERNEL_VERSION"
rpmdev-extract -q "kernel-$KERNEL_VERSION.src.rpm"
mv -n "kernel-$KERNEL_VERSION.src"/* .
rm -r "kernel-$KERNEL_VERSION.src.rpm" "kernel-$KERNEL_VERSION.src"

# Set buildid to .t2
sed -i 's/# define buildid .local/%define buildid .t2/g' "kernel.spec"

# Bump release
# sed -i 's/%define specrelease 200/%define specrelease 210/g' "kernel.spec"

# Disable debug kernels
sed -i "/%define with_debug /c %define with_debug 0" "kernel.spec"

# Add our patches
sed -i "/Patch1:/a Patch2: t2linux-combined.patch" "kernel.spec"
sed -i "/ApplyOptionalPatch patch-%{patchversion}-redhat.patch/a ApplyOptionalPatch t2linux-combined.patch" "kernel.spec"

# extra_config entries go into the x86_64 config files only (see the
# set_kconfig_x86_64 loop below).  kernel-local applies to every arch, and
# generic options there (e.g. CONFIG_I2C=y, CONFIG_MEDIA_*=y for t2bce_ave)
# break the arm64/ppc64le config consistency check in %prep.
cat << 'EOF' > "kernel-local"
CONFIG_SPI_HID_APPLE_OF=y
CONFIG_HID_DOCKCHANNEL=y
CONFIG_APPLE_DOCKCHANNEL=y
CONFIG_APPLE_RTKIT_HELPER=m
EOF

function write_kconfig_to_file {
  config_opt=$(echo "$1" | cut -d'=' -f1)
  if [[ "$config_opt" =~ '# '(.+)' is not set' ]]; then
    config_opt="${BASH_REMATCH[1]}"
  fi
  sed -i "/# $config_opt is not set/d" "$2"
  sed -i "/$config_opt=/d" "$2"
  echo "$1" >> "$2"
}

function set_kconfig_x86_64 {
  for file in \
    "kernel-x86_64-fedora.config" \
    "kernel-x86_64-rt-debug-fedora.config" \
    "kernel-x86_64-rt-fedora.config" \
    "kernel-x86_64-debug-fedora.config"
  do
    write_kconfig_to_file "$1" "$file"
  done
}

set_kconfig_x86_64 'CONFIG_APPLE_BCE=m'

readarray -t extra_config < linux-t2-patches/extra_config
for config in "${extra_config[@]}"; do
  set_kconfig_x86_64 "$config"
done

set_kconfig_x86_64 'CONFIG_INPUT_SPARSEKMAP=y'
set_kconfig_x86_64 'CONFIG_MODULE_FORCE_UNLOAD=y'
set_kconfig_x86_64 'CONFIG_CMDLINE="intel_iommu=on iommu=pt pm_async=off"'
set_kconfig_x86_64 'CONFIG_CMDLINE_BOOL=y'
set_kconfig_x86_64 '# CONFIG_CMDLINE_OVERRIDE is not set'

cat "linux-t2-patches"/*.patch > "t2linux-combined.patch"
