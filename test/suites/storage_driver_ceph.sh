test_storage_driver_ceph() {
  ensure_import_testimage

  # shellcheck disable=2039
  local APOLLO_STORAGE_DIR apollo_backend  

  apollo_backend=$(storage_backend "$APOLLO_DIR")
  APOLLO_STORAGE_DIR=$(mktemp -d -p "${TEST_DIR}" XXXXXXXXX)
  chmod +x "${APOLLO_STORAGE_DIR}"
  spawn_apollo "${APOLLO_STORAGE_DIR}" false

  (
    set -e
    # shellcheck disable=2030
    APOLLO_DIR="${APOLLO_STORAGE_DIR}"

    # shellcheck disable=SC1009
    if [ "$apollo_backend" = "ceph" ]; then
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool1" ceph

      # Set default storage pool for image import.
      mercury profile device add default root disk path="/" pool="apollotest-$(basename "${APOLLO_DIR}")-pool1"

      # Import image into default storage pool.
      ensure_import_testimage

      # create osd pool
      ceph --cluster "${APOLLO_CEPH_CLUSTER}" osd pool create "apollotest-$(basename "${APOLLO_DIR}")-existing-osd-pool" 32

      # Let APOLLO use an already existing osd pool.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-pool2" ceph source="apollotest-$(basename "${APOLLO_DIR}")-existing-osd-pool"

      # Test that no invalid ceph storage pool configuration keys can be set.
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-ceph-pool-config" ceph lvm.thinpool_name=bla
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-ceph-pool-config" ceph lvm.use_thinpool=false
      ! mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-invalid-ceph-pool-config" ceph lvm.vg_name=bla

      # Test that all valid ceph storage pool configuration keys can be set.
      mercury storage create "apollotest-$(basename "${APOLLO_DIR}")-valid-ceph-pool-config" ceph volume.block.filesystem=ext4 volume.block.mount_options=discard volume.size=2GB ceph.rbd.clone_copy=true ceph.osd.pg_num=32
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-valid-ceph-pool-config"
    fi

    # Muck around with some containers on various pools.
    if [ "$apollo_backend" = "ceph" ]; then
      mercury init testimage c1pool1 -s "apollotest-$(basename "${APOLLO_DIR}")-pool1"
      mercury list -c b c1pool1 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool1"

      mercury init testimage c2pool2 -s "apollotest-$(basename "${APOLLO_DIR}")-pool2"
      mercury list -c b c2pool2 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool2"

      mercury launch testimage c3pool1 -s "apollotest-$(basename "${APOLLO_DIR}")-pool1"
      mercury list -c b c3pool1 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool1"

      mercury launch testimage c4pool2 -s "apollotest-$(basename "${APOLLO_DIR}")-pool2"
      mercury list -c b c4pool2 | grep "apollotest-$(basename "${APOLLO_DIR}")-pool2"

      mercury storage volume create "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1
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

    if [ "$apollo_backend" = "ceph" ]; then
      mercury delete -f c1pool1
      mercury delete -f c3pool1

      mercury delete -f c4pool2
      mercury delete -f c2pool2

      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool1" c1pool1
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool1" c2pool2
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool2" c3pool1
      mercury storage volume delete "apollotest-$(basename "${APOLLO_DIR}")-pool2" c4pool2
    fi

    if [ "$apollo_backend" = "ceph" ]; then
      mercury image delete testimage
      mercury profile device remove default root
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool1"
      mercury storage delete "apollotest-$(basename "${APOLLO_DIR}")-pool2"
    fi

  )

  # shellcheck disable=SC2031
  APOLLO_DIR="${APOLLO_DIR}"
  kill_apollo "${APOLLO_STORAGE_DIR}"
}
