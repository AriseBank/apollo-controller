ensure_removed() {
  bad=0
  mercury exec foo -- stat /dev/ttyS0 && bad=1
  if [ "${bad}" -eq 1 ]; then
    echo "device should have been removed; $*"
    false
  fi
}

dounixdevtest() {
    mercury start foo
    mercury config device add foo tty unix-char "$@"
    mercury exec foo -- stat /dev/ttyS0
    mercury restart foo
    mercury exec foo -- stat /dev/ttyS0
    mercury restart foo --force
    mercury exec foo -- stat /dev/ttyS0
    mercury config device remove foo tty
    ensure_removed "was not hot-removed"
    mercury restart foo
    ensure_removed "removed device re-appeared after container reboot"
    mercury restart foo --force
    ensure_removed "removed device re-appaared after mercury reboot"
    mercury stop foo --force
}

testunixdevs() {
  echo "Testing passing char device /dev/ttyS0"
  dounixdevtest path=/dev/ttyS0

  echo "Testing passing char device 4 64"
  dounixdevtest path=/dev/ttyS0 major=4 minor=64

  echo "Testing passing char device source=/dev/ttyS0"
  dounixdevtest source=/dev/ttyS0

  echo "Testing passing char device path=/dev/ttyS0 source=/dev/ttyS0"
  dounixdevtest path=/dev/ttyS0 source=/dev/ttyS0

  echo "Testing passing char device path=/dev/ttyS0 source=/dev/ttyS1"
  dounixdevtest path=/dev/ttyS0 source=/dev/ttyS1
}

ensure_fs_unmounted() {
  bad=0
  mercury exec foo -- stat /mnt/hello && bad=1
  if [ "${bad}" -eq 1 ]; then
    echo "device should have been removed; $*"
    false
  fi
}

testloopmounts() {
  loopfile=$(mktemp -p "${TEST_DIR}" loop_XXX)
  dd if=/dev/zero of="${loopfile}" bs=1M seek=200 count=1
  mkfs.ext4 -F "${loopfile}"

  lpath=$(losetup --show -f "${loopfile}")
  if [ ! -e "${lpath}" ]; then
    echo "failed to setup loop"
    false
  fi
  echo "${lpath}" >> "${TEST_DIR}/loops"

  mkdir -p "${TEST_DIR}/mnt"
  mount "${lpath}" "${TEST_DIR}/mnt" || { echo "loop mount failed"; return; }
  touch "${TEST_DIR}/mnt/hello"
  umount -l "${TEST_DIR}/mnt"
  mercury start foo
  mercury config device add foo mnt disk source="${lpath}" path=/mnt
  mercury exec foo stat /mnt/hello
  # Note - we need to add a set_running_config_item to mercury
  # or work around its absence somehow.  Once that's done, we
  # can run the following two lines:
  #mercury exec foo reboot
  #mercury exec foo stat /mnt/hello
  mercury restart foo --force
  mercury exec foo stat /mnt/hello
  mercury config device remove foo mnt
  ensure_fs_unmounted "fs should have been hot-unmounted"
  mercury restart foo
  ensure_fs_unmounted "removed fs re-appeared after reboot"
  mercury restart foo --force
  ensure_fs_unmounted "removed fs re-appeared after restart"
  mercury stop foo --force
  losetup -d "${lpath}"
  sed -i "\|^${lpath}|d" "${TEST_DIR}/loops"
}

test_mount_order() {
  mkdir -p "${TEST_DIR}/order/empty"
  mkdir -p "${TEST_DIR}/order/full"
  touch "${TEST_DIR}/order/full/filler"

  # The idea here is that sometimes (depending on how golang randomizes the
  # config) the empty dir will have the contents of full in it, but sometimes
  # it won't depending on whether the devices below are processed in order or
  # not. This should not be racy, and they should *always* be processed in path
  # order, so the filler file should always be there.
  mercury config device add foo order disk source="${TEST_DIR}/order" path=/mnt
  mercury config device add foo orderFull disk source="${TEST_DIR}/order/full" path=/mnt/empty

  mercury start foo
  mercury exec foo -- cat /mnt/empty/filler
  mercury stop foo --force
}

test_config_profiles() {
  ensure_import_testimage

  mercury init testimage foo -s "apollotest-$(basename "${APOLLO_DIR}")"
  mercury profile list | grep default

  # let's check that 'mercury config profile' still works while it's deprecated
  mercury config profile list | grep default

  # setting an invalid config item should error out when setting it, not get
  # into the database and never let the user edit the container again.
  ! mercury config set foo raw.mercury "mercury.notaconfigkey = invalid"

  # check that various profile application mechanisms work
  mercury profile create one
  mercury profile create two
  mercury profile assign foo one,two
  [ "$(mercury info foo | grep Profiles)" = "Profiles: one, two" ]
  mercury profile assign foo ""
  [ "$(mercury info foo | grep Profiles)" = "Profiles: " ]
  mercury profile apply foo one # backwards compat check with `mercury profile apply`
  [ "$(mercury info foo | grep Profiles)" = "Profiles: one" ]
  mercury profile assign foo ""
  mercury profile add foo one
  [ "$(mercury info foo | grep Profiles)" = "Profiles: one" ]
  mercury profile remove foo one
  [ "$(mercury info foo | grep Profiles)" = "Profiles: " ]

  mercury profile create stdintest
  echo "BADCONF" | mercury profile set stdintest user.user_data -
  mercury profile show stdintest | grep BADCONF
  mercury profile delete stdintest

  echo "BADCONF" | mercury config set foo user.user_data -
  mercury config show foo | grep BADCONF
  mercury config unset foo user.user_data

  mkdir -p "${TEST_DIR}/mnt1"
  mercury config device add foo mnt1 disk source="${TEST_DIR}/mnt1" path=/mnt1 readonly=true
  mercury profile create onenic
  mercury profile device add onenic eth0 nic nictype=p2p
  mercury profile assign foo onenic
  mercury profile create unconfined
  mercury profile set unconfined raw.mercury "mercury.aa_profile=unconfined"
  mercury profile assign foo onenic,unconfined

  mercury config device list foo | grep mnt1
  mercury config device show foo | grep "/mnt1"
  mercury config show foo | grep "onenic" -A1 | grep "unconfined"
  mercury profile list | grep onenic
  mercury profile device list onenic | grep eth0
  mercury profile device show onenic | grep p2p

  # test live-adding a nic
  mercury start foo
  mercury exec foo -- cat /proc/self/mountinfo | grep -q "/mnt1.*ro,"
  ! mercury config show foo | grep -q "raw.mercury"
  mercury config show foo --expanded | grep -q "raw.mercury"
  ! mercury config show foo | grep -v "volatile.eth0" | grep -q "eth0"
  mercury config show foo --expanded | grep -v "volatile.eth0" | grep -q "eth0"
  mercury config device add foo eth2 nic nictype=p2p name=eth10
  mercury exec foo -- /sbin/ifconfig -a | grep eth0
  mercury exec foo -- /sbin/ifconfig -a | grep eth10
  mercury config device list foo | grep eth2
  mercury config device remove foo eth2

  # test live-adding a disk
  mkdir "${TEST_DIR}/mnt2"
  touch "${TEST_DIR}/mnt2/hosts"
  mercury config device add foo mnt2 disk source="${TEST_DIR}/mnt2" path=/mnt2 readonly=true
  mercury exec foo -- cat /proc/self/mountinfo | grep -q "/mnt2.*ro,"
  mercury exec foo -- ls /mnt2/hosts
  mercury stop foo --force
  mercury start foo
  mercury exec foo -- ls /mnt2/hosts
  mercury config device remove foo mnt2
  ! mercury exec foo -- ls /mnt2/hosts
  mercury stop foo --force
  mercury start foo
  ! mercury exec foo -- ls /mnt2/hosts
  mercury stop foo --force

  mercury config set foo user.prop value
  mercury list user.prop=value | grep foo
  mercury config unset foo user.prop

  # Test for invalid raw.mercury
  ! mercury config set foo raw.mercury a
  ! mercury profile set default raw.mercury a

  bad=0
  mercury list user.prop=value | grep foo && bad=1
  if [ "${bad}" -eq 1 ]; then
    echo "property unset failed"
    false
  fi

  bad=0
  mercury config set foo user.prop 2>/dev/null && bad=1
  if [ "${bad}" -eq 1 ]; then
    echo "property set succeded when it shouldn't have"
    false
  fi

  testunixdevs

  testloopmounts

  test_mount_order

  mercury delete foo

  mercury init testimage foo -s "apollotest-$(basename "${APOLLO_DIR}")"
  mercury profile assign foo onenic,unconfined
  mercury start foo

  if [ -e /sys/module/apparmor ]; then
    mercury exec foo -- cat /proc/self/attr/current | grep unconfined
  fi
  mercury exec foo -- ls /sys/class/net | grep eth0

  mercury stop foo --force
  mercury delete foo
}


test_config_edit() {
    ensure_import_testimage

    mercury init testimage foo -s "apollotest-$(basename "${APOLLO_DIR}")"
    mercury config show foo | sed 's/^description:.*/description: bar/' | mercury config edit foo
    mercury config show foo | grep -q 'description: bar'
    mercury delete foo
}

test_config_edit_container_snapshot_pool_config() {
    # shellcheck disable=2034,2039,2155
    local storage_pool="apollotest-$(basename "${APOLLO_DIR}")"

    ensure_import_testimage

    mercury init testimage c1 -s "$storage_pool"
    mercury snapshot c1 s1
    # edit the container volume name
    mercury storage volume show "$storage_pool" container/c1 | \
        sed 's/^description:.*/description: bar/' | \
        mercury storage volume edit "$storage_pool" container/c1
    mercury storage volume show "$storage_pool" container/c1 | grep -q 'description: bar'
    # edit the container snapshot volume name
    mercury storage volume show "$storage_pool" container/c1/s1 | \
        sed 's/^description:.*/description: baz/' | \
        mercury storage volume edit "$storage_pool" container/c1/s1
    mercury storage volume show "$storage_pool" container/c1/s1 | grep -q 'description: baz'
    mercury delete c1
}

test_container_metadata() {
    ensure_import_testimage
    mercury init testimage c

    # metadata for the container are printed
    mercury config metadata show c | grep -q Busybox

    # metadata can be edited
    mercury config metadata show c | sed 's/Busybox/BB/' | mercury config metadata edit c
    mercury config metadata show c | grep -q BB

    # templates can be listed
    mercury config template list c | grep -q template.tpl

    # template content can be returned
    mercury config template show c template.tpl | grep -q "name:"

    # templates can be added
    mercury config template create c my.tpl
    mercury config template list c | grep -q my.tpl

    # template content can be updated
    echo "some content" | mercury config template edit c my.tpl
    mercury config template show c my.tpl | grep -q "some content"
    
    # templates can be removed
    mercury config template delete c my.tpl
    ! (mercury config template list c | grep -q my.tpl)

    mercury delete c
}
