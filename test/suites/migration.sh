test_migration() {
  # setup a second APOLLO
  # shellcheck disable=2039
  local APOLLO2_DIR APOLLO2_ADDR apollo_backend
  # shellcheck disable=2153
  apollo_backend=$(storage_backend "$APOLLO_DIR")

  APOLLO2_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO2_DIR}"
  spawn_apollo "${APOLLO2_DIR}" true
  APOLLO2_ADDR=$(cat "${APOLLO2_DIR}/apollo.addr")

  # workaround for kernel/criu
  umount /sys/kernel/debug >/dev/null 2>&1 || true

  if ! mercury_remote remote list | grep -q l1; then
    # shellcheck disable=2153
    mercury_remote remote add l1 "${APOLLO_ADDR}" --accept-certificate --password foo
  fi
  if ! mercury_remote remote list | grep -q l2; then
    mercury_remote remote add l2 "${APOLLO2_ADDR}" --accept-certificate --password foo
  fi

  migration "$APOLLO2_DIR"

  # This should only run on lvm and when the backend is not random. Otherwise
  # we might perform existence checks for files or dirs that won't be available
  # since the logical volume is not mounted when the container is not running.
  # shellcheck disable=2153
  if [ "${APOLLO_BACKEND}" = "lvm" ]; then
    # Test that non-thinpool lvm backends work fine with migration.

    # shellcheck disable=2039
    local storage_pool1 storage_pool2
    # shellcheck disable=2153
    storage_pool1="apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-lvm-migration"
    storage_pool2="apollotest-$(basename "${APOLLO2_DIR}")-non-thinpool-lvm-migration"
    mercury_remote storage create l1:"$storage_pool1" lvm lvm.use_thinpool=false volume.size=25MB
    mercury_remote profile device set l1:default root pool "$storage_pool1"

    mercury_remote storage create l2:"$storage_pool2" lvm lvm.use_thinpool=false volume.size=25MB
    mercury_remote profile device set l2:default root pool "$storage_pool2"

    migration "$APOLLO2_DIR"

    mercury_remote profile device set l1:default root pool "apollotest-$(basename "${APOLLO_DIR}")"
    mercury_remote profile device set l2:default root pool "apollotest-$(basename "${APOLLO2_DIR}")"

    mercury_remote storage delete l1:"$storage_pool1"
    mercury_remote storage delete l2:"$storage_pool2"
  fi

  mercury_remote remote remove l2
  kill_apollo "$APOLLO2_DIR"
}

migration() {
  # shellcheck disable=2039
  local apollo2_dir apollo_backend apollo2_backend
  apollo2_dir="$1"
  apollo_backend=$(storage_backend "$APOLLO_DIR")
  apollo2_backend=$(storage_backend "$apollo2_dir")
  ensure_import_testimage

  mercury_remote init testimage nonlive
  # test moving snapshots
  mercury_remote config set l1:nonlive user.tester foo
  mercury_remote snapshot l1:nonlive
  mercury_remote config unset l1:nonlive user.tester
  mercury_remote move l1:nonlive l2:
  mercury_remote config show l2:nonlive/snap0 | grep user.tester | grep foo

  # This line exists so that the container's storage volume is mounted when we
  # perform existence check for various files.
  mercury_remote start l2:nonlive
  # FIXME: make this backend agnostic
  if [ "$apollo2_backend" != "lvm" ] && [ "$apollo2_backend" != "zfs" ] && [ "$apollo2_backend" != "ceph" ]; then
    [ -d "${apollo2_dir}/containers/nonlive/rootfs" ]
  fi
  mercury_remote stop l2:nonlive --force

  [ ! -d "${APOLLO_DIR}/containers/nonlive" ]
  # FIXME: make this backend agnostic
  if [ "$apollo2_backend" = "dir" ]; then
    [ -d "${apollo2_dir}/snapshots/nonlive/snap0/rootfs/bin" ]
  fi

  mercury_remote copy l2:nonlive l1:nonlive2 --mode=push
  # This line exists so that the container's storage volume is mounted when we
  # perform existence check for various files.
  mercury_remote start l2:nonlive
  [ -d "${APOLLO_DIR}/containers/nonlive2" ]
  # FIXME: make this backend agnostic
  if [ "$apollo2_backend" != "lvm" ] && [ "$apollo2_backend" != "zfs" ] && [ "$apollo2_backend" != "ceph" ]; then
    [ -d "${apollo2_dir}/containers/nonlive/rootfs/bin" ]
  fi

  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ -d "${APOLLO_DIR}/snapshots/nonlive2/snap0/rootfs/bin" ]
  fi

  mercury_remote copy l1:nonlive2/snap0 l2:nonlive3 --mode=relay
  # FIXME: make this backend agnostic
  if [ "$apollo2_backend" != "lvm" ] && [ "$apollo2_backend" != "zfs" ] && [ "$apollo2_backend" != "ceph" ]; then
    [ -d "${apollo2_dir}/containers/nonlive3/rootfs/bin" ]
  fi
  mercury_remote delete l2:nonlive3 --force

  mercury_remote stop l2:nonlive --force
  mercury_remote copy l2:nonlive l2:nonlive2 --mode=push
  # should have the same base image tag
  [ "$(mercury_remote config get l2:nonlive volatile.base_image)" = "$(mercury_remote config get l2:nonlive2 volatile.base_image)" ]
  # check that nonlive2 has a new addr in volatile
  [ "$(mercury_remote config get l2:nonlive volatile.eth0.hwaddr)" != "$(mercury_remote config get l2:nonlive2 volatile.eth0.hwaddr)" ]

  mercury_remote config unset l2:nonlive volatile.base_image
  mercury_remote copy l2:nonlive l1:nobase
  mercury_remote delete l1:nobase

  mercury_remote start l1:nonlive2
  mercury_remote list l1: | grep RUNNING | grep nonlive2
  mercury_remote delete l1:nonlive2 l2:nonlive2 --force

  mercury_remote start l2:nonlive
  mercury_remote list l2: | grep RUNNING | grep nonlive
  mercury_remote delete l2:nonlive --force

  # Test container only copies
  mercury init testimage cccp
  echo "before" | mercury file push - cccp/blah
  mercury snapshot cccp
  mercury snapshot cccp
  echo "after" | mercury file push - cccp/blah

  # Local container only copy.
  mercury copy cccp udssr --container-only
  [ "$(mercury info udssr | grep -c snap)" -eq 0 ]
  [ "$(mercury file pull udssr/blah -)" = "after" ]
  mercury delete udssr

  # Local container with snapshots copy.
  mercury copy cccp udssr
  [ "$(mercury info udssr | grep -c snap)" -eq 2 ]
  [ "$(mercury file pull udssr/blah -)" = "after" ]
  mercury delete udssr

  # Remote container only copy.
  mercury_remote copy l1:cccp l2:udssr --container-only
  [ "$(mercury_remote info l2:udssr | grep -c snap)" -eq 0 ]
  [ "$(mercury_remote file pull l2:udssr/blah -)" = "after" ]
  mercury_remote delete l2:udssr

  # Remote container with snapshots copy.
  mercury_remote copy l1:cccp l2:udssr
  [ "$(mercury_remote info l2:udssr | grep -c snap)" -eq 2 ]
  [ "$(mercury_remote file pull l2:udssr/blah -)" = "after" ]
  mercury_remote delete l2:udssr

  # Remote container only move.
  mercury_remote move l1:cccp l2:udssr --container-only --mode=relay
  ! mercury_remote info l1:cccp
  [ "$(mercury_remote info l2:udssr | grep -c snap)" -eq 0 ]
  mercury_remote delete l2:udssr

  mercury_remote init testimage l1:cccp
  mercury_remote snapshot l1:cccp
  mercury_remote snapshot l1:cccp

  # Remote container with snapshots move.
  mercury_remote move l1:cccp l2:udssr --mode=push
  ! mercury_remote info l1:cccp
  [ "$(mercury_remote info l2:udssr | grep -c snap)" -eq 2 ]
  mercury_remote delete l2:udssr

  # Test container only copies
  mercury init testimage cccp
  mercury snapshot cccp
  mercury snapshot cccp

  # Local container with snapshots move.
  mercury move cccp udssr --mode=pull
  ! mercury info cccp
  [ "$(mercury info udssr | grep -c snap)" -eq 2 ]
  mercury delete udssr

  if [ "$apollo_backend" = "zfs" ]; then
    # Test container only copies when zfs.clone_copy is set to false.
    mercury storage set "apollotest-$(basename "${APOLLO_DIR}")" zfs.clone_copy false
    mercury init testimage cccp
    mercury snapshot cccp
    mercury snapshot cccp

    # Test container only copies when zfs.clone_copy is set to false.
    mercury copy cccp udssr --container-only
    [ "$(mercury info udssr | grep -c snap)" -eq 0 ]
    mercury delete udssr

    # Test container with snapshots copy when zfs.clone_copy is set to false.
    mercury copy cccp udssr
    [ "$(mercury info udssr | grep -c snap)" -eq 2 ]
    mercury delete cccp
    mercury delete udssr

    mercury storage unset "apollotest-$(basename "${APOLLO_DIR}")" zfs.clone_copy
  fi

  if ! which criu >/dev/null 2>&1; then
    echo "==> SKIP: live migration with CRIU (missing binary)"
    return
  fi

  mercury_remote launch testimage l1:migratee

  # let the container do some interesting things
  sleep 1s

  mercury_remote stop --stateful l1:migratee
  mercury_remote start l1:migratee
  mercury_remote snapshot --stateful l1:migratee
  mercury_remote stop -f l1:migratee
  mercury_remote copy l1:migratee/snap0 l2:migratee
  ! mercury_remote copy l1:migratee/snap0 l2:migratee-new-name
  mercury_remote copy --stateless l1:migratee/snap0 l2:migratee-new-name

  mercury_remote delete --force l1:migratee
  mercury_remote delete --force l2:migratee
  mercury_remote delete --force l2:migratee-new-name
}
