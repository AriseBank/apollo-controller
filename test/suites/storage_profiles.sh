test_storage_profiles() {
  # shellcheck disable=2039

  APOLLO_STORAGE_DIR=$(mktemp -d -p "${TEST_DIR}" XXXXXXXXX)
  chmod +x "${APOLLO_STORAGE_DIR}"
  spawn_apollo "${APOLLO_STORAGE_DIR}" false
  (
    set -e
    # shellcheck disable=2030
    APOLLO_DIR="${APOLLO_STORAGE_DIR}"

    HAS_ZFS="dir"
    if which zfs >/dev/null 2>&1; then
      HAS_ZFS="zfs"
    fi

    HAS_BTRFS="dir"
    if which btrfs >/dev/null 2>&1; then
      HAS_BTRFS="btrfs"
    fi

    # shellcheck disable=SC1009
    # Create loop file zfs pool.
    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool1" "${HAS_ZFS}"

    # Create loop file btrfs pool.
    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool2" "${HAS_BTRFS}"

    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool4" dir

    # Set default storage pool for image import.
    mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"

    # Import image into default storage pool.
    ensure_import_testimage

    mercury profile create dummy

    # Create a new profile that provides a root device for some containers.
    mercury profile device add dummy rootfs disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"

    # Begin interesting test cases.

    for i in $(seq 1 3); do
      mercury launch testimage c"${i}" --profile dummy
    done

    # Check that we can't remove or change the root disk device since containers
    # are actually using it.
    ! mercury profile device remove dummy rootfs
    ! mercury profile device set dummy rootfs pool "apollotest-$(basename "${APOLLO_DIR}")-pool2"

    # Give all the containers we started their own local root disk device.
    for i in $(seq 1 2); do
      ! mercury config device add c"${i}" root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"
      mercury config device add c"${i}" rootfs disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"
    done

    # Try to set new pool. This should fail since there is a single container
    # that has no local root disk device.
    ! mercury profile device set dummy rootfs pool "apollotest-$(basename "${APOLLO_DIR}")-pool2"
    # This should work since it doesn't change the pool property.
    mercury profile device set dummy rootfs pool "apollotest-$(basename "${APOLLO_DIR}")-pool1"
    # Check that we can not remove the root disk device since there is a single
    # container that is still using it.
    ! mercury profile device remove dummy rootfs

    # Give the last container a local root disk device.
    ! mercury config device add c3 root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"
    mercury config device add c3 rootfs disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"

    # Try to set new pool. This should work since the container has a local disk
    mercury profile device set dummy rootfs pool "apollotest-$(basename "${APOLLO_DIR}")-pool2"
    mercury profile device set dummy rootfs pool "apollotest-$(basename "${APOLLO_DIR}")-pool1"
    # Check that we can now remove the root disk device since no container is
    # actually using it.
    mercury profile device remove dummy rootfs

    # Add back a root device to the profile.
    ! mercury profile device add dummy rootfs1 disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"

    # Try to add another root device to the profile that tries to set a pool
    # property. This should fail. This is also a test for whether it is possible
    # to put multiple disk devices on the same path. This must fail!
    ! mercury profile device add dummy rootfs2 disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool2"

    # Add another root device to the profile that does not set a pool property.
    # This should not work since it would use the same path.
    ! mercury profile device add dummy rootfs3 disk path="/"

    # Create a second profile.
    mercury profile create dummyDup
    mercury profile device add dummyDup rootfs1 disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"

    # Create a third profile
    mercury profile create dummyNoDup
    mercury profile device add dummyNoDup rootfs2 disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool2"

    # Verify that we cannot create a container with profiles that have
    # contradicting root devices.
    ! mercury launch testimage cConflictingProfiles --p dummy -p dummyDup -p dummyNoDup

    # And that even with a local disk, a container can't have multiple root devices
    ! mercury launch testimage cConflictingProfiles -s "apollotest-$(basename "${APOLLO_DIR}")-pool2" -p dummy -p dummyDup -p dummyNoDup

    # Check that we cannot assign conflicting profiles to a container that
    # relies on another profiles root disk device.
    mercury launch testimage cOnDefault
    ! mercury profile assign cOnDefault default,dummyDup,dummyNoDup

    # Verify that we can create a container with two profiles that speficy the
    # same root disk device.
    mercury launch testimage cNonConflictingProfiles -p dummy -p dummyDup

    # Try to remove the root disk device from one of the profiles.
    mercury profile device remove dummy rootfs1

    # Try to remove the root disk device from the second profile.
    ! mercury profile device remove dummyDup rootfs1

    # Test that we can't remove the root disk device from the containers config
    # when the profile it is attached to specifies no root device.
    for i in $(seq 1 3); do
      ! mercury config device remove c"${i}" root
      # Must fail.
      ! mercury profile assign c"${i}" dummyDup,dummyNoDup
    done

    mercury delete -f cNonConflictingProfiles
    mercury delete -f cOnDefault
    for i in $(seq 1 3); do
      mercury delete -f c"${i}"
    done

  )

  # shellcheck disable=SC2031
  APOLLO_DIR="${APOLLO_DIR}"
  kill_apollo "${APOLLO_STORAGE_DIR}"
}
