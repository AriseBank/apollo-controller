test_init_interactive() {
  # - apollo init
  APOLLO_INIT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO_INIT_DIR}"
  spawn_apollo "${APOLLO_INIT_DIR}" false

  (
    set -e
    # shellcheck disable=SC2034
    APOLLO_DIR=${APOLLO_INIT_DIR}

    # XXX We need to remove the eth0 device from the default profile, which
    #     is typically attached by spawn_apollo.
    if mercury profile show default | grep -q eth0; then
      mercury profile device remove default eth0
    fi

    cat <<EOF | apollo init
yes
my-storage-pool
dir
no
no
yes
apollot$$
auto
none
EOF

    mercury info | grep -q 'images.auto_update_interval: "0"'
    mercury network list | grep -q "apollot$$"
    mercury storage list | grep -q "my-storage-pool"
    mercury profile show default | grep -q "pool: my-storage-pool"
    mercury profile show default | grep -q "parent: apollot$$"
    mercury profile delete default
    mercury network delete apollot$$
  )
  kill_apollo "${APOLLO_INIT_DIR}"

  return
}
