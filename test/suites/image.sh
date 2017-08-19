test_image_expiry() {
  # shellcheck disable=2039
  local APOLLO2_DIR APOLLO2_ADDR
  APOLLO2_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO2_DIR}"
  spawn_apollo "${APOLLO2_DIR}" true
  APOLLO2_ADDR=$(cat "${APOLLO2_DIR}/apollo.addr")

  ensure_import_testimage

  if ! mercury_remote remote list | grep -q l1; then
    # shellcheck disable=2153
    mercury_remote remote add l1 "${APOLLO_ADDR}" --accept-certificate --password foo
  fi
  if ! mercury_remote remote list | grep -q l2; then
    mercury_remote remote add l2 "${APOLLO2_ADDR}" --accept-certificate --password foo
  fi
  mercury_remote init l1:testimage l2:c1
  fp=$(mercury_remote image info testimage | awk -F: '/^Fingerprint/ { print $2 }' | awk '{ print $1 }')
  [ ! -z "${fp}" ]
  fpbrief=$(echo "${fp}" | cut -c 1-10)

  mercury_remote image list l2: | grep -q "${fpbrief}"

  mercury_remote remote set-default l2
  mercury_remote config set images.remote_cache_expiry 0
  mercury_remote remote set-default local

  ! mercury_remote image list l2: | grep -q "${fpbrief}"

  mercury_remote delete l2:c1

  # reset the default expiry
  mercury_remote remote set-default l2
  mercury_remote config set images.remote_cache_expiry 10
  mercury_remote remote set-default local

  mercury_remote remote remove l2
  kill_apollo "$APOLLO2_DIR"
}

test_image_list_all_aliases() {
    ensure_import_testimage
    # shellcheck disable=2039,2034,2155
    local sum=$(mercury image info testimage | grep ^Fingerprint | cut -d' ' -f2)
    mercury image alias create zzz "$sum"
    mercury image list | grep -vq zzz
    # both aliases are listed if the "aliases" column is included in output
    mercury image list -c L | grep -q testimage
    mercury image list -c L | grep -q zzz

}

test_image_import_dir() {
    ensure_import_testimage
    mercury image export testimage
    # shellcheck disable=2039,2034,2155
    local image=$(ls -1 -- *.tar.xz)
    mkdir -p unpacked
    tar -C unpacked -xf "$image"
    # shellcheck disable=2039,2034,2155
    local fingerprint=$(mercury image import unpacked | awk '{print $NF;}')
    rm -rf "$image" unpacked

    mercury image export "$fingerprint"
    # shellcheck disable=2039,2034,2155
    local exported="${fingerprint}.tar.xz"

    tar tvf "$exported" | grep -Fq metadata.yaml
    rm "$exported"
}

test_image_import_existing_alias() {
    ensure_import_testimage
    mercury init testimage c
    mercury publish c --alias newimage --alias image2
    mercury delete c
    mercury image export testimage testimage.file
    mercury image delete testimage
    # the image can be imported with an existing alias
    mercury image import testimage.file --alias newimage
    mercury image delete newimage image2
}
