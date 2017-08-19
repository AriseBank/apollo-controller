zfs_setup() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Setting up ZFS backend in ${APOLLO_DIR}"
}

zfs_configure() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Configuring ZFS backend in ${APOLLO_DIR}"

  mercury storage create "apollotest-$(basename "${APOLLO_DIR}")" zfs size=100GB
  mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")"
}

zfs_teardown() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Tearing down ZFS backend in ${APOLLO_DIR}"
}
