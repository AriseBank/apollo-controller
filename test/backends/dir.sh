# Nothing need be done for the dir backed, but we still need some functions.
# This file can also serve as a skel file for what needs to be done to
# implement a new backend.

# Any necessary backend-specific setup
dir_setup() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Setting up directory backend in ${APOLLO_DIR}"
}

# Do the API voodoo necessary to configure APOLLO to use this backend
dir_configure() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Configuring directory backend in ${APOLLO_DIR}"

  mercury storage create "apollotest-$(basename "${APOLLO_DIR}")" dir
  mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")"
}

dir_teardown() {
  # shellcheck disable=2039
  local APOLLO_DIR

  APOLLO_DIR=$1

  echo "==> Tearing down directory backend in ${APOLLO_DIR}"
}
