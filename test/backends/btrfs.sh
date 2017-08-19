btrfs_setup() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Setting up btrfs backend in ${APOLLO_DIR}"
}

btrfs_configure() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  mercury storage create "apollotest-$(basename "${APOLLO_DIR}")" btrfs size=100GB
  mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")"

  echo "==> Configuring btrfs backend in ${APOLLO_DIR}"
}

btrfs_teardown() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Tearing down btrfs backend in ${APOLLO_DIR}"
}
