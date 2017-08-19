#!/bin/sh -eu
[ -n "${GOPATH:-}" ] && export "PATH=${GOPATH}/bin:${PATH}"

# Don't translate mercury output for parsing in it in tests.
export LC_ALL="C"

# Force UTC for consistency
export TZ="UTC"

if [ -n "${APOLLO_VERBOSE:-}" ] || [ -n "${APOLLO_DEBUG:-}" ]; then
  set -x
fi

export DEBUG=""
if [ -n "${APOLLO_VERBOSE:-}" ]; then
  DEBUG="--verbose"
fi

if [ -n "${APOLLO_DEBUG:-}" ]; then
  DEBUG="--debug"
fi

if [ -z "${APOLLO_BACKEND:-}" ]; then
    APOLLO_BACKEND="dir"
fi

import_subdir_files() {
    test "$1"
    # shellcheck disable=SC2039
    local file
    for file in "$1"/*.sh; do
        # shellcheck disable=SC1090
        . "$file"
    done
}

import_subdir_files includes

echo "==> Checking for dependencies"
check_dependencies apollo mercury curl dnsmasq jq git xgettext sqlite3 msgmerge msgfmt shuf setfacl uuidgen

if [ "${USER:-'root'}" != "root" ]; then
  echo "The testsuite must be run as root." >&2
  exit 1
fi

if [ -n "${APOLLO_LOGS:-}" ] && [ ! -d "${APOLLO_LOGS}" ]; then
  echo "Your APOLLO_LOGS path doesn't exist: ${APOLLO_LOGS}"
  exit 1
fi

echo "==> Available storage backends: $(available_storage_backends | sort)"
if [ "$APOLLO_BACKEND" != "random" ] && ! storage_backend_available "$APOLLO_BACKEND"; then
  if [ "${APOLLO_BACKEND}" = "ceph" ] && [ -z "${APOLLO_CEPH_CLUSTER:-}" ]; then
    echo "Ceph storage backend requires that \"APOLLO_CEPH_CLUSTER\" be set."
    exit 1
  fi
  echo "Storage backend \"$APOLLO_BACKEND\" is not available"
  exit 1
fi
echo "==> Using storage backend ${APOLLO_BACKEND}"

import_storage_backends

cleanup() {
  # Allow for failures and stop tracing everything
  set +ex
  DEBUG=

  # Allow for inspection
  if [ -n "${APOLLO_INSPECT:-}" ]; then
    if [ "${TEST_RESULT}" != "success" ]; then
      echo "==> TEST DONE: ${TEST_CURRENT_DESCRIPTION}"
    fi
    echo "==> Test result: ${TEST_RESULT}"

    # shellcheck disable=SC2086
    printf "To poke around, use:\n APOLLO_DIR=%s APOLLO_CONF=%s sudo -E %s/bin/mercury COMMAND\n" "${APOLLO_DIR}" "${APOLLO_CONF}" ${GOPATH:-}
    echo "Tests Completed (${TEST_RESULT}): hit enter to continue"

    # shellcheck disable=SC2034
    read -r nothing
  fi

  echo "==> Cleaning up"

  cleanup_apollos "$TEST_DIR"


  echo ""
  echo ""
  if [ "${TEST_RESULT}" != "success" ]; then
    echo "==> TEST DONE: ${TEST_CURRENT_DESCRIPTION}"
  fi
  echo "==> Test result: ${TEST_RESULT}"
}

# Must be set before cleanup()
TEST_CURRENT=setup
# shellcheck disable=SC2034
TEST_RESULT=failure

trap cleanup EXIT HUP INT TERM

# Import all the testsuites
import_subdir_files suites

# Setup test directory
TEST_DIR=$(mktemp -d -p "$(pwd)" tmp.XXX)
chmod +x "${TEST_DIR}"

if [ -n "${APOLLO_TMPFS:-}" ]; then
  mount -t tmpfs tmpfs "${TEST_DIR}" -o mode=0751
fi

APOLLO_CONF=$(mktemp -d -p "${TEST_DIR}" XXX)
export APOLLO_CONF

APOLLO_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
export APOLLO_DIR
chmod +x "${APOLLO_DIR}"
spawn_apollo "${APOLLO_DIR}" true
APOLLO_ADDR=$(cat "${APOLLO_DIR}/apollo.addr")
export APOLLO_ADDR

run_test() {
  TEST_CURRENT=${1}
  TEST_CURRENT_DESCRIPTION=${2:-${1}}

  echo "==> TEST BEGIN: ${TEST_CURRENT_DESCRIPTION}"
  START_TIME=$(date +%s)
  ${TEST_CURRENT}
  END_TIME=$(date +%s)

  echo "==> TEST DONE: ${TEST_CURRENT_DESCRIPTION} ($((END_TIME-START_TIME))s)"
}

# allow for running a specific set of tests
if [ "$#" -gt 0 ]; then
  run_test "test_${1}"
  # shellcheck disable=SC2034
  TEST_RESULT=success
  exit
fi

run_test test_check_deps "checking dependencies"
run_test test_static_analysis "static analysis"
run_test test_database_update "database schema updates"
run_test test_remote_url "remote url handling"
run_test test_remote_admin "remote administration"
run_test test_remote_usage "remote usage"
run_test test_basic_usage "basic usage"
run_test test_security "security features"
run_test test_image_expiry "image expiry"
run_test test_image_list_all_aliases "image list all aliases"
run_test test_image_auto_update "image auto-update"
run_test test_image_prefer_cached "image prefer cached"
run_test test_image_import_dir "import image from directory"
run_test test_concurrent_exec "concurrent exec"
run_test test_concurrent "concurrent startup"
run_test test_snapshots "container snapshots"
run_test test_snap_restore "snapshot restores"
run_test test_config_profiles "profiles and configuration"
run_test test_config_edit "container configuration edit"
run_test test_config_edit_container_snapshot_pool_config "container and snapshot volume configuration edit"
run_test test_container_metadata "manage container metadata and templates"
run_test test_server_config "server configuration"
run_test test_filemanip "file manipulations"
run_test test_network "network management"
run_test test_idmap "id mapping"
run_test test_template "file templating"
run_test test_pki "PKI mode"
run_test test_devapollo "/dev/apollo"
run_test test_fuidshift "fuidshift"
run_test test_migration "migration"
run_test test_fdleak "fd leak"
run_test test_cpu_profiling "CPU profiling"
run_test test_mem_profiling "memory profiling"
run_test test_storage "storage"
run_test test_init_auto "apollo init auto"
run_test test_init_interactive "apollo init interactive"
run_test test_init_preseed "apollo init preseed"
run_test test_storage_profiles "storage profiles"
run_test test_container_import "container import"
run_test test_storage_volume_attach "attaching storage volumes"
run_test test_storage_driver_ceph "ceph storage driver"

# shellcheck disable=SC2034
TEST_RESULT=success
