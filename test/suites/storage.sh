test_storage() {
  ensure_import_testimage

  # shellcheck disable=2039
  local APOLLO_STORAGE_DIR apollo_backend  

  apollo_backend=$(storage_backend "$APOLLO_DIR")
  APOLLO_STORAGE_DIR=$(mktemp -d -p "${TEST_DIR}" XXXXXXXXX)
  chmod +x "${APOLLO_STORAGE_DIR}"
  spawn_apollo "${APOLLO_STORAGE_DIR}" false

  # edit storage and pool description
  # shellcheck disable=2039
  local storage_pool storage_volume
  storage_pool="apollotest-$(basename "${APOLLO_DIR}")-pool"
  storage_volume="${storage_pool}-vol"
  mercury storage create "$storage_pool" "$apollo_backend"
  mercury storage show "$storage_pool" | sed 's/^description:.*/description: foo/' | mercury storage edit "$storage_pool"
  mercury storage show "$storage_pool" | grep -q 'description: foo'

  mercury storage volume create "$storage_pool" "$storage_volume"
  if [ "$apollo_backend" != "dir" ] && [ "$apollo_backend" != "ceph" ]; then
    # Test resizing/applying quota to a storage volume.
    mercury storage volume set "$storage_pool" "$storage_volume" size 500MB
    mercury storage volume unset "$storage_pool" "$storage_volume" size
  fi
  # Test setting description on a storage volume
  mercury storage volume show "$storage_pool" "$storage_volume" | sed 's/^description:.*/description: bar/' | mercury storage volume edit "$storage_pool" "$storage_volume"
  mercury storage volume show "$storage_pool" "$storage_volume" | grep -q 'description: bar'
  mercury storage volume delete "$storage_pool" "$storage_volume"

  mercury storage delete "$storage_pool"
  (
    set -e
    # shellcheck disable=2030
    APOLLO_DIR="${APOLLO_STORAGE_DIR}"

    # shellcheck disable=SC1009
    if [ "$apollo_backend" = "zfs" ]; then
    # Create loop file zfs pool.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool1" zfs

      # Check that we can't create a loop file in a non-APOLLO owned location.
      INVALID_LOOP_FILE="$(mktemp -p "${APOLLO_DIR}" XXXXXXXXX)-invalid-loop-file"
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool1" zfs source="${INVALID_LOOP_FILE}"

      # Let APOLLO use an already existing dataset.
      zfs create -p -o mountpoint=none "apollotest-$(basename "${APOLLO_DIR}")-pool1/existing-dataset-as-pool"
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool7" zfs source="apollotest-$(basename "${APOLLO_DIR}")-pool1/existing-dataset-as-pool"

      # Let APOLLO use an already existing storage pool.
      configure_loop_device loop_file_4 loop_device_4
      # shellcheck disable=SC2154
      zpool create "apollotest-$(basename "${APOLLO_DIR}")-pool9-existing-pool" "${loop_device_4}" -f -m none -O compression=on
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool9" zfs source="apollotest-$(basename "${APOLLO_DIR}")-pool9-existing-pool"

      # Let APOLLO create a new dataset and use as pool.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool8" zfs source="apollotest-$(basename "${APOLLO_DIR}")-pool1/non-existing-dataset-as-pool"

      # Create device backed zfs pool
      configure_loop_device loop_file_1 loop_device_1
      # shellcheck disable=SC2154
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool2" zfs source="${loop_device_1}"

      # Test that no invalid zfs storage pool configuration keys can be set.
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-zfs-pool-config" zfs lvm.thinpool_name=bla
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-zfs-pool-config" zfs lvm.use_thinpool=false
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-zfs-pool-config" zfs lvm.vg_name=bla
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-zfs-pool-config" zfs volume.block.filesystem=ext4
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-zfs-pool-config" zfs volume.block.mount_options=discard
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-zfs-pool-config" zfs volume.size=2GB

      # Test that all valid zfs storage pool configuration keys can be set.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config" zfs volume.zfs.remove_snapshots=true
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config"

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config" zfs volume.zfs.use_refquota=true
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config"

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config" zfs zfs.clone_copy=true
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config"

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config" zfs zfs.pool_name="apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config"
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config"

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config" zfs rsync.bwlimit=1024
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-zfs-pool-config"
    fi

    if [ "$apollo_backend" = "btrfs" ]; then
      # Create loop file btrfs pool.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool3" btrfs

      # Create device backed btrfs pool.
      configure_loop_device loop_file_2 loop_device_2
      # shellcheck disable=SC2154
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool4" btrfs source="${loop_device_2}"

      # Check that we cannot create storage pools inside of ${APOLLO_DIR} other than ${APOLLO_DIR}/storage-pools/{pool_name}.
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool5_under_apollo_dir" btrfs source="${APOLLO_DIR}"

      # Test that no invalid btrfs storage pool configuration keys can be set.
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs lvm.thinpool_name=bla
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs lvm.use_thinpool=false
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs lvm.vg_name=bla
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs volume.block.filesystem=ext4
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs volume.block.mount_options=discard
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs volume.size=2GB
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs volume.zfs.remove_snapshots=true
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs volume.zfs.use_refquota=true
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs zfs.clone_copy=true
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-btrfs-pool-config" btrfs zfs.pool_name=bla

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-btrfs-pool-config" btrfs rsync.bwlimit=1024
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-btrfs-pool-config"

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-btrfs-pool-config" btrfs btrfs.mount_options="rw,strictatime,nospace_cache,user_subvol_rm_allowed"
      mercury storage set "apollotest-$(basename "${APOLLO_DIR}")-valid-btrfs-pool-config" btrfs.mount_options "rw,relatime,space_cache,user_subvol_rm_allowed"
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-btrfs-pool-config"
    fi

    # Create dir pool.
    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool5" dir

    # Check that we cannot create storage pools inside of ${APOLLO_DIR} other than ${APOLLO_DIR}/storage-pools/{pool_name}.
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool5_under_apollo_dir" dir source="${APOLLO_DIR}"

    # Check that we can create storage pools inside of ${APOLLO_DIR}/storage-pools/{pool_name}.
    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool5_under_apollo_dir" dir source="${APOLLO_DIR}/storage-pools/apollotest-$(basename "${APOLLO_DIR}")-pool5_under_apollo_dir"

    mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool5_under_apollo_dir"

    # Test that no invalid dir storage pool configuration keys can be set.
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir lvm.thinpool_name=bla
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir lvm.use_thinpool=false
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir lvm.vg_name=bla
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir size=10GB
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir volume.block.filesystem=ext4
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir volume.block.mount_options=discard
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir volume.size=2GB
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir volume.zfs.remove_snapshots=true
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir volume.zfs.use_refquota=true
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir zfs.clone_copy=true
    ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-dir-pool-config" dir zfs.pool_name=bla

    mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-dir-pool-config" dir rsync.bwlimit=1024
    mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-dir-pool-config"

    if [ "$apollo_backend" = "lvm" ]; then
      # Create lvm pool.
      configure_loop_device loop_file_3 loop_device_3
      # shellcheck disable=SC2154
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool6" lvm source="${loop_device_3}" volume.size=25MB

      configure_loop_device loop_file_5 loop_device_5
      # shellcheck disable=SC2154
      # Should fail if vg does not exist, since we have no way of knowing where
      # to create the vg without a block device path set.
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool10" lvm source=dummy_vg_1 volume.size=25MB
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_5}" "${loop_device_5}"

      configure_loop_device loop_file_6 loop_device_6
      # shellcheck disable=SC2154
      pvcreate "${loop_device_6}"
      vgcreate "apollotest-$(basename "${APOLLO_DIR}")-pool11-dummy_vg_2" "${loop_device_6}"
      # Reuse existing volume group "dummy_vg_2" on existing physical volume.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool11" lvm source="apollotest-$(basename "${APOLLO_DIR}")-pool11-dummy_vg_2" volume.size=25MB

      configure_loop_device loop_file_7 loop_device_7
      # shellcheck disable=SC2154
      pvcreate "${loop_device_7}"
      vgcreate "apollotest-$(basename "${APOLLO_DIR}")-pool12-dummy_vg_3" "${loop_device_7}"
      # Reuse existing volume group "dummy_vg_3" on existing physical volume.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool12" lvm source="apollotest-$(basename "${APOLLO_DIR}")-pool12-dummy_vg_3" volume.size=25MB

      configure_loop_device loop_file_8 loop_device_8
      # shellcheck disable=SC2154
      # Create new volume group "dummy_vg_4".
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool13" lvm source="${loop_device_8}" lvm.vg_name="apollotest-$(basename "${APOLLO_DIR}")-pool13-dummy_vg_4" volume.size=25MB

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool14" lvm volume.size=25MB

      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" lvm lvm.use_thinpool=false volume.size=25MB

      # Test that no invalid lvm storage pool configuration keys can be set.
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-lvm-pool-config" lvm volume.zfs.remove_snapshots=true
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-lvm-pool-config" lvm volume.zfs_use_refquota=true
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-lvm-pool-config" lvm zfs.clone_copy=true
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-lvm-pool-config" lvm zfs.pool_name=bla
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-lvm-pool-config" lvm lvm.use_thinpool=false lvm.thinpool_name="apollotest-$(basename "${APOLLO_DIR}")-invalid-lvm-pool-config"

      # Test that all valid lvm storage pool configuration keys can be set.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool16" lvm lvm.thinpool_name="apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config"
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool17" lvm lvm.vg_name="apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config"
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool18" lvm size=10GB
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool19" lvm volume.block.filesystem=ext4
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool20" lvm volume.block.mount_options=discard
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool21" lvm volume.size=2GB
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool22" lvm lvm.use_thinpool=true
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool23" lvm lvm.use_thinpool=true lvm.thinpool_name="apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config"
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool24" lvm rsync.bwlimit=1024
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool25" lvm volume.block.mount_options="rw,strictatime,discard"
      mercury storage set "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool25" volume.block.mount_options "rw,lazytime"
    fi

    # Set default storage pool for image import.
    mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool5"

    # Import image into default storage pool.
    ensure_import_testimage

    # Muck around with some containers on various pools.
    if [ "$apollo_backend" = "zfs" ]; then
      mercury init testimage c1pool1 -s "apollotest-$(basename "${APOLLO_DIR}")-pool1"
      mercury list -c b c1pool1 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool1"

      mercury init testimage c2pool2 -s "apollotest-$(basename "${APOLLO_DIR}")-pool2"
      mercury list -c b c2pool2 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool2"

      mercury launch testimage c3pool1 -s "apollotest-$(basename "${APOLLO_DIR}")-pool1"
      mercury list -c b c3pool1 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool1"

      mercury launch testimage c4pool2 -s "apollotest-$(basename "${APOLLO_DIR}")-pool2"
      mercury list -c b c4pool2 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool2"

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1
      mercury storage volume set "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1 zfs.use_refquota true
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1 c1pool1 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1 c1pool1 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1 c1pool1
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" custom/c1pool1 c1pool1 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" custom/c1pool1 c1pool1 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1 c1pool1

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool1" c2pool2
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c2pool2 c2pool2 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c2pool2 c2pool2 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c2pool2 c2pool2
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" custom/c2pool2 c2pool2 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool1" custom/c2pool2 c2pool2 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool1" c2pool2 c2pool2

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1 c3pool1 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1 c3pool1 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1 c3pool1
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1 c3pool1 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1 c3pool1 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1 c3pool1

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool2" c4pool2
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c4pool2 c4pool2 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c4pool2 c4pool2 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c4pool2 c4pool2
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" custom/c4pool2 c4pool2 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool2" custom/c4pool2 c4pool2 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool2" c4pool2 c4pool2
    fi

    if [ "$apollo_backend" = "btrfs" ]; then
      mercury init testimage c5pool3 -s "apollotest-$(basename "${APOLLO_DIR}")-pool3"
      mercury list -c b c5pool3 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool3"
      mercury init testimage c6pool4 -s "apollotest-$(basename "${APOLLO_DIR}")-pool4"
      mercury list -c b c6pool4 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool4"

      mercury launch testimage c7pool3 -s "apollotest-$(basename "${APOLLO_DIR}")-pool3"
      mercury list -c b c7pool3 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool3"
      mercury launch testimage c8pool4 -s "apollotest-$(basename "${APOLLO_DIR}")-pool4"
      mercury list -c b c8pool4 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool4"

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool3" c5pool3
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c5pool3 c5pool3 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c5pool3 c5pool3 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c5pool3 c5pool3 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" custom/c5pool3 c5pool3 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" custom/c5pool3 c5pool3 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c5pool3 c5pool3 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool4" c6pool4
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c6pool4 c5pool3 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c6pool4 c5pool3 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c6pool4 c5pool3 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" custom/c6pool4 c5pool3 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" custom/c6pool4 c5pool3 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c6pool4 c5pool3 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool3" c7pool3
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c7pool3 c7pool3 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c7pool3 c7pool3 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c7pool3 c7pool3 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" custom/c7pool3 c7pool3 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool3" custom/c7pool3 c7pool3 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool3" c7pool3 c7pool3 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool4" c8pool4
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c8pool4 c8pool4 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c8pool4 c8pool4 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c8pool4 c8pool4 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" custom/c8pool4 c8pool4 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool4" custom/c8pool4 c8pool4 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool4" c8pool4 c8pool4 testDevice
    fi

    mercury init testimage c9pool5 -s "apollotest-$(basename "${APOLLO_DIR}")-pool5"
    mercury list -c b c9pool5 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool5"

    mercury launch testimage c11pool5 -s "apollotest-$(basename "${APOLLO_DIR}")-pool5"
    mercury list -c b c11pool5 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool5"

    mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool5" c9pool5
    mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c9pool5 c9pool5 testDevice /opt
    ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c9pool5 c9pool5 testDevice2 /opt
    mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c9pool5 c9pool5 testDevice
    mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" custom/c9pool5 c9pool5 testDevice /opt
    ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" custom/c9pool5 c9pool5 testDevice2 /opt
    mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c9pool5 c9pool5 testDevice

    mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool5" c11pool5
    mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c11pool5 c11pool5 testDevice /opt
    ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c11pool5 c11pool5 testDevice2 /opt
    mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c11pool5 c11pool5 testDevice
    mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" custom/c11pool5 c11pool5 testDevice /opt
    ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool5" custom/c11pool5 c11pool5 testDevice2 /opt
    mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool5" c11pool5 c11pool5 testDevice

    if [ "$apollo_backend" = "lvm" ]; then
      mercury init testimage c10pool6 -s "apollotest-$(basename "${APOLLO_DIR}")-pool6"
      mercury list -c b c10pool6 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool6"

      # Test if volume group renaming works by setting lvm.vg_name.
      mercury storage set "apollotest-$(basename "${APOLLO_DIR}")-pool6" lvm.vg_name "apollotest-$(basename "${APOLLO_DIR}")-pool6-newName"

      mercury storage set "apollotest-$(basename "${APOLLO_DIR}")-pool6" lvm.thinpool_name "apollotest-$(basename "${APOLLO_DIR}")-pool6-newThinpoolName"

      mercury launch testimage c12pool6 -s "apollotest-$(basename "${APOLLO_DIR}")-pool6"
      mercury list -c b c12pool6 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool6"
      # grow lv
      mercury config device set c12pool6 root size 30MB
      mercury restart c12pool6 --force
      # shrink lv
      mercury config device set c12pool6 root size 25MB
      mercury restart c12pool6 --force

      mercury init testimage c10pool11 -s "apollotest-$(basename "${APOLLO_DIR}")-pool11"
      mercury list -c b c10pool11 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool11"

      mercury launch testimage c12pool11 -s "apollotest-$(basename "${APOLLO_DIR}")-pool11"
      mercury list -c b c12pool11 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool11"

      mercury init testimage c10pool12 -s "apollotest-$(basename "${APOLLO_DIR}")-pool12"
      mercury list -c b c10pool12 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool12"

      mercury launch testimage c12pool12 -s "apollotest-$(basename "${APOLLO_DIR}")-pool12"
      mercury list -c b c12pool12 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool12"

      mercury init testimage c10pool13 -s "apollotest-$(basename "${APOLLO_DIR}")-pool13"
      mercury list -c b c10pool13 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool13"

      mercury launch testimage c12pool13 -s "apollotest-$(basename "${APOLLO_DIR}")-pool13"
      mercury list -c b c12pool13 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool13"

      mercury init testimage c10pool14 -s "apollotest-$(basename "${APOLLO_DIR}")-pool14"
      mercury list -c b c10pool14 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool14"

      mercury launch testimage c12pool14 -s "apollotest-$(basename "${APOLLO_DIR}")-pool14"
      mercury list -c b c12pool14 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool14"

      mercury init testimage c10pool15 -s "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15"
      mercury list -c b c10pool15 | grep "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15"

      mercury launch testimage c12pool15 -s "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15"
      mercury list -c b c12pool15 | grep "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15"

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool6" c10pool6
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c10pool6 c10pool6 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c10pool6 c10pool6 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c10pool6 c10pool6 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" custom/c10pool6 c10pool6 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" custom/c10pool6 c10pool6 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c10pool6 c10pool6 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool6" c12pool6
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c12pool6 c12pool6 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c12pool6 c12pool6 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c12pool6 c12pool6 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" custom/c12pool6 c12pool6 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool6" custom/c12pool6 c12pool6 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool6" c12pool6 c12pool6 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool11" c10pool11
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c10pool11 c10pool11 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c10pool11 c10pool11 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c10pool11 c10pool11 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" custom/c10pool11 c10pool11 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" custom/c10pool11 c10pool11 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c10pool11 c10pool11 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool11" c12pool11
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c12pool11 c10pool11 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c12pool11 c10pool11 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c12pool11 c10pool11 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" custom/c12pool11 c10pool11 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool11" custom/c12pool11 c10pool11 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool11" c12pool11 c10pool11 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool12" c10pool12
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c10pool12 c10pool12 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c10pool12 c10pool12 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c10pool12 c10pool12 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" custom/c10pool12 c10pool12 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" custom/c10pool12 c10pool12 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c10pool12 c10pool12 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool12" c12pool12
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c12pool12 c12pool12 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c12pool12 c12pool12 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c12pool12 c12pool12 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" custom/c12pool12 c12pool12 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool12" custom/c12pool12 c12pool12 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool12" c12pool12 c12pool12 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool13" c10pool13
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c10pool13 c10pool13 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c10pool13 c10pool13 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c10pool13 c10pool13 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" custom/c10pool13 c10pool13 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" custom/c10pool13 c10pool13 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c10pool13 c10pool13 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool13" c12pool13
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c12pool13 c12pool13 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c12pool13 c12pool13 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c12pool13 c12pool13 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" custom/c12pool13 c12pool13 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool13" custom/c12pool13 c12pool13 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool13" c12pool13 c12pool13 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool14" c10pool14
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c10pool14 c10pool14 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c10pool14 c10pool14 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c10pool14 c10pool14 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" custom/c10pool14 c10pool14 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" custom/c10pool14 c10pool14 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c10pool14 c10pool14 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool14" c12pool14
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c12pool14 c12pool14 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c12pool14 c12pool14 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c12pool14 c12pool14 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" custom/c12pool14 c12pool14 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool14" custom/c12pool14 c12pool14 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool14" c12pool14 c12pool14 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c10pool15
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c10pool15 c10pool15 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c10pool15 c10pool15 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c10pool15 c10pool15 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" custom/c10pool15 c10pool15 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" custom/c10pool15 c10pool15 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c10pool15 c10pool15 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c12pool15
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c12pool15 c12pool15 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c12pool15 c12pool15 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c12pool15 c12pool15 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" custom/c12pool15 c12pool15 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" custom/c12pool15 c12pool15 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c12pool15 c12pool15 testDevice
    fi

    if [ "$apollo_backend" = "zfs" ]; then
      mercury launch testimage c13pool7 -s "apollotest-$(basename "${APOLLO_DIR}")-pool7"
      mercury launch testimage c14pool7 -s "apollotest-$(basename "${APOLLO_DIR}")-pool7"

      mercury launch testimage c15pool8 -s "apollotest-$(basename "${APOLLO_DIR}")-pool8"
      mercury launch testimage c16pool8 -s "apollotest-$(basename "${APOLLO_DIR}")-pool8"

      mercury launch testimage c17pool9 -s "apollotest-$(basename "${APOLLO_DIR}")-pool9"
      mercury launch testimage c18pool9 -s "apollotest-$(basename "${APOLLO_DIR}")-pool9"

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool7" c13pool7
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c13pool7 c13pool7 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c13pool7 c13pool7 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c13pool7 c13pool7 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" custom/c13pool7 c13pool7 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" custom/c13pool7 c13pool7 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c13pool7 c13pool7 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool7" c14pool7
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c14pool7 c14pool7 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c14pool7 c14pool7 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c14pool7 c14pool7 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" custom/c14pool7 c14pool7 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool7" custom/c14pool7 c14pool7 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool7" c14pool7 c14pool7 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool8" c15pool8
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c15pool8 c15pool8 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c15pool8 c15pool8 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c15pool8 c15pool8 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" custom/c15pool8 c15pool8 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" custom/c15pool8 c15pool8 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c15pool8 c15pool8 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool8" c16pool8
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c16pool8 c16pool8 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c16pool8 c16pool8 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c16pool8 c16pool8 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" custom/c16pool8 c16pool8 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool8" custom/c16pool8 c16pool8 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool8" c16pool8 c16pool8 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool9" c17pool9
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c17pool9 c17pool9 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c17pool9 c17pool9 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c17pool9 c17pool9 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" custom/c17pool9 c17pool9 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" custom/c17pool9 c17pool9 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c17pool9 c17pool9 testDevice

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool9" c18pool9
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c18pool9 c18pool9 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c18pool9 c18pool9 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c18pool9 c18pool9 testDevice
      mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" custom/c18pool9 c18pool9 testDevice /opt
      ! mercury storage volume attach "apollotest-$(basename "${APOLLO_DIR}")-pool9" custom/c18pool9 c18pool9 testDevice2 /opt
      mercury storage volume detach "apollotest-$(basename "${APOLLO_DIR}")-pool9" c18pool9 c18pool9 testDevice
    fi

    if [ "$apollo_backend" = "zfs" ]; then
      mercury delete -f c1pool1
      mercury delete -f c3pool1

      mercury delete -f c4pool2
      mercury delete -f c2pool2

      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool1" c2pool2
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool2" c4pool2
    fi

    if [ "$apollo_backend" = "btrfs" ]; then
      mercury delete -f c5pool3
      mercury delete -f c7pool3

      mercury delete -f c8pool4
      mercury delete -f c6pool4

      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool3" c5pool3
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool4" c6pool4
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool3" c7pool3
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool4" c8pool4
    fi

    mercury delete -f c9pool5
    mercury delete -f c11pool5

    mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool5" c9pool5
    mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool5" c11pool5

    if [ "$apollo_backend" = "lvm" ]; then
      mercury delete -f c10pool6
      mercury delete -f c12pool6

      mercury delete -f c10pool11
      mercury delete -f c12pool11

      mercury delete -f c10pool12
      mercury delete -f c12pool12

      mercury delete -f c10pool13
      mercury delete -f c12pool13

      mercury delete -f c10pool14
      mercury delete -f c12pool14

      mercury delete -f c10pool15
      mercury delete -f c12pool15

      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool6" c10pool6
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool6"  c12pool6
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool11" c10pool11
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool11" c12pool11
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool12" c10pool12
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool12" c12pool12
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool13" c10pool13
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool13" c12pool13
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool14" c10pool14
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool14" c12pool14
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c10pool15
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" c12pool15
    fi

    if [ "$apollo_backend" = "zfs" ]; then
      mercury delete -f c13pool7
      mercury delete -f c14pool7

      mercury delete -f c15pool8
      mercury delete -f c16pool8

      mercury delete -f c17pool9
      mercury delete -f c18pool9

      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool7" c13pool7
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool7" c14pool7
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool8" c15pool8
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool8" c16pool8
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool9" c17pool9
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool9" c18pool9
    fi

    mercury image delete testimage

    if [ "$apollo_backend" = "zfs" ]; then
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool7"
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool8"
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool9"
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_4}" "${loop_device_4}"

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool1"

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool2"
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_1}" "${loop_device_1}"
    fi

    if [ "$apollo_backend" = "btrfs" ]; then
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool4"
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_2}" "${loop_device_2}"
    fi

    if [ "$apollo_backend" = "lvm" ]; then
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool6"
      # shellcheck disable=SC2154
      pvremove -ff "${loop_device_3}" || true
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_3}" "${loop_device_3}"

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool11"
      # shellcheck disable=SC2154
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-pool11-dummy_vg_2" || true
      pvremove -ff "${loop_device_6}" || true
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_6}" "${loop_device_6}"

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool12"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-pool12-dummy_vg_3" || true
      pvremove -ff "${loop_device_7}" || true
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_7}" "${loop_device_7}"

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool13"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-pool13-dummy_vg_4" || true
      pvremove -ff "${loop_device_8}" || true
      # shellcheck disable=SC2154
      deconfigure_loop_device "${loop_file_8}" "${loop_device_8}"

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool14"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-pool14" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool15" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool16"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool16" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool17"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool17" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool18"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool18" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool19"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool19" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool20"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool20" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool21"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool21" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool22"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool22" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool23"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool23" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool24"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool24" || true

      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-lvm-pool-config-pool25"
      vgremove -ff "apollotest-$(basename "${APOLLO_DIR}")-non-thinpool-pool25" || true
    fi
  )

  # Test applying quota
  QUOTA1="10GB"
  QUOTA2="11GB"
  if [ "$apollo_backend" = "lvm" ]; then
    QUOTA1="20MB"
    QUOTA2="21MB"
  fi

  if [ "$apollo_backend" != "dir" ] && [ "$apollo_backend" != "ceph" ]; then
    mercury launch testimage quota1
    mercury profile device set default root size "${QUOTA1}"
    mercury stop -f quota1
    mercury start quota1

    mercury launch testimage quota2
    mercury stop -f quota2
    mercury start quota2

    mercury init testimage quota3
    mercury start quota3

    mercury profile device set default root size "${QUOTA2}"

    mercury stop -f quota1
    mercury start quota1

    mercury stop -f quota2
    mercury start quota2

    mercury stop -f quota3
    mercury start quota3

    mercury profile device unset default root size
    mercury stop -f quota1
    mercury start quota1

    mercury stop -f quota2
    mercury start quota2

    mercury stop -f quota3
    mercury start quota3

    mercury delete -f quota1
    mercury delete -f quota2
    mercury delete -f quota3
  fi

  # shellcheck disable=SC2031
  APOLLO_DIR="${APOLLO_DIR}"
  kill_apollo "${APOLLO_STORAGE_DIR}"
}
