test_security() {
  ensure_import_testimage
  ensure_has_localhost_remote "${APOLLO_ADDR}"

  # CVE-2016-1581
  if [ "$(storage_backend "$APOLLO_DIR")" = "zfs" ]; then
    APOLLO_INIT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
    chmod +x "${APOLLO_INIT_DIR}"
    spawn_apollo "${APOLLO_INIT_DIR}" false

    ZFS_POOL="apollotest-$(basename "${APOLLO_DIR}")-init"
    APOLLO_DIR=${APOLLO_INIT_DIR} apollo init --storage-backend zfs --storage-create-loop 1 --storage-pool "${ZFS_POOL}" --auto

    PERM=$(stat -c %a "${APOLLO_INIT_DIR}/disks/${ZFS_POOL}.img")
    if [ "${PERM}" != "600" ]; then
      echo "Bad zfs.img permissions: ${PERM}"
      false
    fi

    kill_apollo "${APOLLO_INIT_DIR}"
  fi

  # CVE-2016-1582
  mercury launch testimage test-priv -c security.privileged=true

  PERM=$(stat -L -c %a "${APOLLO_DIR}/containers/test-priv")
  if [ "${PERM}" != "700" ]; then
    echo "Bad container permissions: ${PERM}"
    false
  fi

  mercury config set test-priv security.privileged false
  mercury restart test-priv --force
  mercury config set test-priv security.privileged true
  mercury restart test-priv --force

  PERM=$(stat -L -c %a "${APOLLO_DIR}/containers/test-priv")
  if [ "${PERM}" != "700" ]; then
    echo "Bad container permissions: ${PERM}"
    false
  fi

  mercury delete test-priv --force

  mercury launch testimage test-unpriv
  mercury config set test-unpriv security.privileged true
  mercury restart test-unpriv --force

  PERM=$(stat -L -c %a "${APOLLO_DIR}/containers/test-unpriv")
  if [ "${PERM}" != "700" ]; then
    echo "Bad container permissions: ${PERM}"
    false
  fi

  mercury delete test-unpriv --force
}
