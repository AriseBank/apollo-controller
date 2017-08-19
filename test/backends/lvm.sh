lvm_setup() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Setting up lvm backend in ${APOLLO_DIR}"
}

lvm_configure() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Configuring lvm backend in ${APOLLO_DIR}"

  mercury storage create "apollotest-$(basename "${APOLLO_DIR}")" lvm volume.size=25MB
  mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")"
}

lvm_teardown() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Tearing down lvm backend in ${APOLLO_DIR}"
}
