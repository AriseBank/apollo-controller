test_image_auto_update() {
  # XXX this test appears to be flaky when running on Jenkins
  # against the LVM backend. Needs further investigation.
  # shellcheck disable=2153
  backend=$(storage_backend "$APOLLO_DIR")
  if [ "${backend}" = "lvm" ]; then
      return 0
  fi

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

  # Restart the server to force an image refresh immediately
  # shellcheck disable=2153
  shutdown_apollo "${APOLLO_DIR}"
  respawn_apollo "${APOLLO_DIR}"

  # Check that the first image got deleted from the local storage
  #
  # XXX: Since the auto-update logic runs asynchronously we need to wait
  #      a little bit before it actually completes.
  retries=10
  while [ "${retries}" != "0" ]; do
    if mercury image info "${fp1}" > /dev/null 2>&1; then
        sleep 2
        retries=$((retries-1))
        continue
    fi
    break
  done

  if [ "${retries}" -eq 0 ]; then
      echo "First image ${fp1} not deleted from local store"
      return 1
  fi

  # The second image replaced the first one in the local storage.
  alias=$(mercury image info "${fp2}" | awk -F: '/^    Alias/ { print $2 }' | awk '{ print $1 }')
  [ "${alias}" = "testimage" ]

  mercury delete c1
  mercury remote remove l2
  mercury image delete "${fp2}"
  kill_apollo "$APOLLO2_DIR"
}
