test_init_preseed() {
  # - apollo init --preseed
  apollo_backend=$(storage_backend "$APOLLO_DIR")
  APOLLO_INIT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO_INIT_DIR}"
  spawn_apollo "${APOLLO_INIT_DIR}" false

  (
    set -e
    # shellcheck disable=SC2034
    APOLLO_DIR=${APOLLO_INIT_DIR}

    # In case we're running against the ZFS backend, let's test
    # creating a zfs storage pool, otherwise just use dir.
    if [ "$apollo_backend" = "zfs" ]; then
        configure_loop_device loop_file_4 loop_device_4
        # shellcheck disable=SC2154
        zpool create "apollotest-$(basename "${APOLLO_DIR}")-preseed-pool" "${loop_device_4}" -f -m none -O compression=on
        driver="zfs"
        source="apollotest-$(basename "${APOLLO_DIR}")-preseed-pool"
    elif [ "$apollo_backend" = "ceph" ]; then
        driver="ceph"
        source=""
    else
        driver="dir"
        source=""
    fi

    cat <<EOF | apollo init --preseed
config:
  core.https_address: 127.0.0.1:9999
  images.auto_update_interval: 15
storage_pools:
- name: data
  driver: $driver
  config:
    source: $source
networks:
- name: apollot$$
  type: bridge
  config:
    ipv4.address: none
    ipv6.address: none
profiles:
- name: default
  devices:
    root:
      path: /
      pool: data
      type: disk
- name: test-profile
  description: "Test profile"
  config:
    limits.memory: 2GB
  devices:
    test0:
      name: test0
      nictype: bridged
      parent: apollot$$
      type: nic
EOF
  
    mercury info | grep -q 'core.https_address: 127.0.0.1:9999'
    mercury info | grep -q 'images.auto_update_interval: "15"'
    mercury network list | grep -q "apollot$$"
    mercury storage list | grep -q "data"
    mercury storage show data | grep -q "$source"
    mercury profile list | grep -q "test-profile"
    mercury profile show default | grep -q "pool: data"
    mercury profile show test-profile | grep -q "limits.memory: 2GB"
    mercury profile show test-profile | grep -q "nictype: bridged"
    mercury profile show test-profile | grep -q "parent: apollot$$"
    mercury profile delete default
    mercury profile delete test-profile
    mercury network delete apollot$$
    mercury storage delete data

    if [ "$apollo_backend" = "zfs" ]; then
        # shellcheck disable=SC2154
        deconfigure_loop_device "${loop_file_4}" "${loop_device_4}"
    fi
  )
  kill_apollo "${APOLLO_INIT_DIR}"
}
