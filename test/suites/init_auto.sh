test_init_auto() {
  # - apollo init --auto --storage-backend zfs
  # and
  # - apollo init --auto
  # can't be easily tested on jenkins since it hard-codes "default" as pool
  # naming. This can cause naming conflicts when multiple test-suites are run on
  # a single runner.

  if [ "$(storage_backend "$APOLLO_DIR")" = "zfs" ]; then
    # apollo init --auto --storage-backend zfs --storage-pool <name>
    APOLLO_INIT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
    chmod +x "${APOLLO_INIT_DIR}"
    spawn_apollo "${APOLLO_INIT_DIR}" false

    configure_loop_device loop_file_1 loop_device_1
    # shellcheck disable=SC2154
    zpool create "apollotest-$(basename "${APOLLO_DIR}")-pool1-existing-pool" "${loop_device_1}" -m none -O compression=on
    APOLLO_DIR=${APOLLO_INIT_DIR} apollo init --auto --storage-backend zfs --storage-pool "apollotest-$(basename "${APOLLO_DIR}")-pool1-existing-pool"
    APOLLO_DIR=${APOLLO_INIT_DIR} mercury profile show default | grep -q "pool: default"

    kill_apollo "${APOLLO_INIT_DIR}"
    sed -i "\|^${loop_device_1}|d" "${TEST_DIR}/loops"

    # apollo init --auto --storage-backend zfs --storage-pool <name>/<non-existing-dataset>
    APOLLO_INIT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
    chmod +x "${APOLLO_INIT_DIR}"
    spawn_apollo "${APOLLO_INIT_DIR}" false

    # shellcheck disable=SC2154
    configure_loop_device loop_file_1 loop_device_1
    zpool create "apollotest-$(basename "${APOLLO_DIR}")-pool1-existing-pool" "${loop_device_1}" -m none -O compression=on
    APOLLO_DIR=${APOLLO_INIT_DIR} apollo init --auto --storage-backend zfs --storage-pool "apollotest-$(basename "${APOLLO_DIR}")-pool1-existing-pool/non-existing-dataset"

    kill_apollo "${APOLLO_INIT_DIR}"

    # apollo init --auto --storage-backend zfs --storage-pool <name>/<existing-dataset>
    APOLLO_INIT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
    chmod +x "${APOLLO_INIT_DIR}"
    spawn_apollo "${APOLLO_INIT_DIR}" false

    zfs create -p -o mountpoint=none "apollotest-$(basename "${APOLLO_DIR}")-pool1-existing-pool/existing-dataset"
    APOLLO_DIR=${APOLLO_INIT_DIR} apollo init --auto --storage-backend zfs --storage-pool "apollotest-$(basename "${APOLLO_DIR}")-pool1-existing-pool/existing-dataset"

    kill_apollo "${APOLLO_INIT_DIR}"
    zpool destroy "apollotest-$(basename "${APOLLO_DIR}")-pool1-existing-pool"
    sed -i "\|^${loop_device_1}|d" "${TEST_DIR}/loops"

    # apollo init --storage-backend zfs --storage-create-loop 1 --storage-pool <name> --auto
    APOLLO_INIT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
    chmod +x "${APOLLO_INIT_DIR}"
    spawn_apollo "${APOLLO_INIT_DIR}" false

    ZFS_POOL="apollotest-$(basename "${APOLLO_DIR}")-init"
    APOLLO_DIR=${APOLLO_INIT_DIR} apollo init --storage-backend zfs --storage-create-loop 1 --storage-pool "${ZFS_POOL}" --auto

    kill_apollo "${APOLLO_INIT_DIR}"
  fi
}
