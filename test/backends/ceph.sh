ceph_setup() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Setting up CEPH backend in ${APOLLO_DIR}"
}

ceph_configure() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Configuring CEPH backend in ${APOLLO_DIR}"

  mercury storage create "apollotest-$(basename "${APOLLO_DIR}")" ceph
  mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")"
}

ceph_teardown() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Tearing down CEPH backend in ${APOLLO_DIR}"
}
