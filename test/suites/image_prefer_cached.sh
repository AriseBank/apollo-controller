# In case a cached image matching the desired alias is present, that
# one is preferred, even if the its remote has a more recent one.
test_image_prefer_cached() {

  if mercury image alias list | grep -q "^| testimage\s*|.*$"; then
      mercury image delete testimage
  fi

  # shellcheck disable=2039
  local APOLLO2_DIR APOLLO2_ADDR
  APOLLO2_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO2_DIR}"
  spawn_apollo "${APOLLO2_DIR}" true
  APOLLO2_ADDR=$(cat "${APOLLO2_DIR}/apollo.addr")

  (APOLLO_DIR=${APOLLO2_DIR} deps/import-busybox --alias testimage --public)
  fp1=$(APOLLO_DIR=${APOLLO2_DIR} mercury image info testimage | awk -F: '/^Fingerprint/ { print $2 }' | awk '{ print $1 }')

  mercury remote add l2 "${APOLLO2_ADDR}" --accept-certificate --password foo
  mercury init l2:testimage c1

  # Now the first image image is in the local store, since it was
  # downloaded to create c1.
  alias=$(mercury image info "${fp1}" | awk -F: '/^    Alias/ { print $2 }' | awk '{ print $1 }')
  [ "${alias}" = "testimage" ]

  # Delete the first image from the remote store and replace it with a
  # new one with a different fingerprint (passing "--template create"
  # will do that).
  (APOLLO_DIR=${APOLLO2_DIR} mercury image delete testimage)
  (APOLLO_DIR=${APOLLO2_DIR} deps/import-busybox --alias testimage --public --template create)
  fp2=$(APOLLO_DIR=${APOLLO2_DIR} mercury image info testimage | awk -F: '/^Fingerprint/ { print $2 }' | awk '{ print $1 }')
  [ "${fp1}" != "${fp2}" ]

  # At this point starting a new container from "testimage" should not
  # result in the new image being downloaded.
  mercury init l2:testimage c2
  if mercury image info "${fp2}"; then
      echo "The second image ${fp2} was downloaded and the cached one not used"
      return 1
  fi

  mercury delete c1
  mercury delete c2
  mercury remote remove l2
  mercury image delete "${fp1}"

  kill_apollo "$APOLLO2_DIR"
}
