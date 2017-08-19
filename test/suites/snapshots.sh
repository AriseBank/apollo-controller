test_snapshots() {
  snapshots

  if [ "$(storage_backend "$APOLLO_DIR")" = "lvm" ]; then
    # Test that non-thinpool lvm backends work fine with snaphots.
    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-lvm-snapshots" lvm lvm.use_thinpool=false volume.size=25MB
    mercury profile device set default root pool "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-lvm-snapshots"

    snapshots

    mercury profile device set default root pool "apollotest-$(basename "${APOLLO_DIR}")"

    mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-lvm-snapshots"
  fi
}

snapshots() {
  # shellcheck disable=2039
  local apollo_backend
  apollo_backend=$(storage_backend "$APOLLO_DIR")

  ensure_import_testimage
  ensure_has_localhost_remote "${APOLLO_ADDR}"

  mercury init testimage foo

  mercury snapshot foo
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ -d "${APOLLO_DIR}/snapshots/foo/snap0" ]
  fi

  mercury snapshot foo
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ -d "${APOLLO_DIR}/snapshots/foo/snap1" ]
  fi

  mercury snapshot foo tester
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ -d "${APOLLO_DIR}/snapshots/foo/tester" ]
  fi

  mercury copy foo/tester foosnap1
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" != "lvm" ] && [ "${apollo_backend}" != "zfs" ] && [ "$apollo_backend" != "ceph" ]; then
    [ -d "${APOLLO_DIR}/containers/foosnap1/rootfs" ]
  fi

  mercury delete foo/snap0
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ ! -d "${APOLLO_DIR}/snapshots/foo/snap0" ]
  fi

  # no CLI for this, so we use the API directly (rename a snapshot)
  wait_for "${APOLLO_ADDR}" my_curl -X POST "https://${APOLLO_ADDR}/1.0/containers/foo/snapshots/tester" -d "{\"name\":\"tester2\"}"
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ ! -d "${APOLLO_DIR}/snapshots/foo/tester" ]
  fi

  mercury move foo/tester2 foo/tester-two
  mercury delete foo/tester-two
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ ! -d "${APOLLO_DIR}/snapshots/foo/tester-two" ]
  fi

  mercury snapshot foo namechange
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ -d "${APOLLO_DIR}/snapshots/foo/namechange" ]
  fi
  mercury move foo foople
  [ ! -d "${APOLLO_DIR}/containers/foo" ]
  [ -d "${APOLLO_DIR}/containers/foople" ]
  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    [ -d "${APOLLO_DIR}/snapshots/foople/namechange" ]
    [ -d "${APOLLO_DIR}/snapshots/foople/namechange" ]
  fi

  mercury delete foople
  mercury delete foosnap1
  [ ! -d "${APOLLO_DIR}/containers/foople" ]
  [ ! -d "${APOLLO_DIR}/containers/foosnap1" ]
}

test_snap_restore() {
  snap_restore

  if [ "$(storage_backend "$APOLLO_DIR")" = "lvm" ]; then
    # Test that non-thinpool lvm backends work fine with snaphots.
    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-lvm-snap-restore" lvm lvm.use_thinpool=false volume.size=25MB
    mercury profile device set default root pool "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-lvm-snap-restore"

    snap_restore

    mercury profile device set default root pool "apollotest-$(basename "${APOLLO_DIR}")"

    mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-lvm-snap-restore"
  fi
}

snap_restore() {
  # shellcheck disable=2039
  local apollo_backend
  apollo_backend=$(storage_backend "$APOLLO_DIR")

  ensure_import_testimage
  ensure_has_localhost_remote "${APOLLO_ADDR}"

  ##########################################################
  # PREPARATION
  ##########################################################

  ## create some state we will check for when snapshot is restored

  ## prepare snap0
  mercury launch testimage bar
  echo snap0 > state
  mercury file push state bar/root/state
  mercury file push state bar/root/file_only_in_snap0
  mercury exec bar -- mkdir /root/dir_only_in_snap0
  mercury exec bar -- ln -s file_only_in_snap0 /root/statelink
  mercury stop bar --force

  mercury snapshot bar snap0

  ## prepare snap1
  mercury start bar
  echo snap1 > state
  mercury file push state bar/root/state
  mercury file push state bar/root/file_only_in_snap1

  mercury exec bar -- rmdir /root/dir_only_in_snap0
  mercury exec bar -- rm /root/file_only_in_snap0
  mercury exec bar -- rm /root/statelink
  mercury exec bar -- ln -s file_only_in_snap1 /root/statelink
  mercury exec bar -- mkdir /root/dir_only_in_snap1
  mercury stop bar --force

  # Delete the state file we created to prevent leaking.
  rm state

  mercury config set bar limits.cpu 1

  mercury snapshot bar snap1

  ##########################################################

  if [ "$apollo_backend" != "zfs" ]; then
    # The problem here is that you can't `zfs rollback` to a snapshot with a
    # parent, which snap0 has (snap1).
    restore_and_compare_fs snap0

    # Check container config has been restored (limits.cpu is unset)
    cpus=$(mercury config get bar limits.cpu)
    if [ -n "${cpus}" ]; then
      echo "==> config didn't match expected value after restore (${cpus})"
      false
    fi
  fi

  ##########################################################

  # test restore using full snapshot name
  restore_and_compare_fs snap1

  # Check config value in snapshot has been restored
  cpus=$(mercury config get bar limits.cpu)
  if [ "${cpus}" != "1" ]; then
   echo "==> config didn't match expected value after restore (${cpus})"
   false
  fi

  ##########################################################

  # Start container and then restore snapshot to verify the running state after restore.
  mercury start bar

  if [ "$apollo_backend" != "zfs" ]; then
    # see comment above about snap0
    restore_and_compare_fs snap0

    # check container is running after restore
    mercury list | grep bar | grep RUNNING
  fi

  mercury stop --force bar

  mercury delete bar

  # Test if container's with hyphen's in their names are treated correctly.
  if [ "$apollo_backend" = "lvm" ]; then
    mercury launch testimage a-b
    mercury snapshot a-b base
    mercury restore a-b base

    mercury snapshot a-b c-d
    mercury restore a-b c-d

    mercury delete -f a-b
  fi
}

restore_and_compare_fs() {
  snap=${1}
  echo "==> Restoring ${snap}"

  mercury restore bar "${snap}"

  # FIXME: make this backend agnostic
  if [ "$(storage_backend "$APOLLO_DIR")" = "dir" ]; then
    # Recursive diff of container FS
    diff -r "${APOLLO_DIR}/containers/bar/rootfs" "${APOLLO_DIR}/snapshots/bar/${snap}/rootfs"
  fi
}
