test_basic_usage() {
  # shellcheck disable=2039
  local apollo_backend
  apollo_backend=$(storage_backend "$APOLLO_DIR")

  ensure_import_testimage
  ensure_has_localhost_remote "${APOLLO_ADDR}"

  # Test image export
  sum=$(mercury image info testimage | grep ^Fingerprint | cut -d' ' -f2)
  mercury image export testimage "${APOLLO_DIR}/"
  [ "${sum}" = "$(sha256sum "${APOLLO_DIR}/${sum}.tar.xz" | cut -d' ' -f1)" ]

  # Test an alias with slashes
  mercury image show "${sum}"
  mercury image alias create a/b/ "${sum}"
  mercury image alias delete a/b/

  # Test alias list filtering
  mercury image alias create foo "${sum}"
  mercury image alias create bar "${sum}"
  mercury image alias list local: | grep -q foo
  mercury image alias list local: | grep -q bar
  mercury image alias list local: foo | grep -q -v bar
  mercury image alias list local: "${sum}" | grep -q foo
  mercury image alias list local: non-existent | grep -q -v non-existent
  mercury image alias delete foo
  mercury image alias delete bar

  # Test image list output formats (table & json)
  mercury image list --format table | grep -q testimage
  mercury image list --format json \
    | jq '.[]|select(.alias[0].name="testimage")' \
    | grep -q '"name": "testimage"'

  # Test image delete
  mercury image delete testimage

  # test GET /1.0, since the client always puts to /1.0/
  my_curl -f -X GET "https://${APOLLO_ADDR}/1.0"
  my_curl -f -X GET "https://${APOLLO_ADDR}/1.0/containers"

  # Re-import the image
  mv "${APOLLO_DIR}/${sum}.tar.xz" "${APOLLO_DIR}/testimage.tar.xz"
  mercury image import "${APOLLO_DIR}/testimage.tar.xz" --alias testimage
  rm "${APOLLO_DIR}/testimage.tar.xz"

  # Test filename for image export
  mercury image export testimage "${APOLLO_DIR}/"
  [ "${sum}" = "$(sha256sum "${APOLLO_DIR}/${sum}.tar.xz" | cut -d' ' -f1)" ]
  rm "${APOLLO_DIR}/${sum}.tar.xz"

  # Test custom filename for image export
  mercury image export testimage "${APOLLO_DIR}/foo"
  [ "${sum}" = "$(sha256sum "${APOLLO_DIR}/foo" | cut -d' ' -f1)" ]
  rm "${APOLLO_DIR}/foo"


  # Test image export with a split image.
  deps/import-busybox --split --alias splitimage

  sum=$(mercury image info splitimage | grep ^Fingerprint | cut -d' ' -f2)

  mercury image export splitimage "${APOLLO_DIR}"
  [ "${sum}" = "$(cat "${APOLLO_DIR}/meta-${sum}.tar.xz" "${APOLLO_DIR}/${sum}.tar.xz" | sha256sum | cut -d' ' -f1)" ]

  # Delete the split image and exported files
  rm "${APOLLO_DIR}/${sum}.tar.xz"
  rm "${APOLLO_DIR}/meta-${sum}.tar.xz"
  mercury image delete splitimage

  # Redo the split image export test, this time with the --filename flag
  # to tell import-busybox to set the 'busybox' filename in the upload.
  # The sum should remain the same as its the same image.
  deps/import-busybox --split --filename --alias splitimage

  mercury image export splitimage "${APOLLO_DIR}"
  [ "${sum}" = "$(cat "${APOLLO_DIR}/meta-${sum}.tar.xz" "${APOLLO_DIR}/${sum}.tar.xz" | sha256sum | cut -d' ' -f1)" ]

  # Delete the split image and exported files
  rm "${APOLLO_DIR}/${sum}.tar.xz"
  rm "${APOLLO_DIR}/meta-${sum}.tar.xz"
  mercury image delete splitimage


  # Test container creation
  mercury init testimage foo
  mercury list | grep foo | grep STOPPED
  mercury list fo | grep foo | grep STOPPED

  # Test list json format
  mercury list --format json | jq '.[]|select(.name="foo")' | grep '"name": "foo"'

  # Test list with --columns and --fast
  ! mercury list --columns=nsp --fast

  # Test container rename
  mercury move foo bar
  mercury list | grep -v foo
  mercury list | grep bar

  # Test container copy
  mercury copy bar foo
  mercury delete foo

  # gen untrusted cert
  gen_cert client3

  # don't allow requests without a cert to get trusted data
  curl -k -s -X GET "https://${APOLLO_ADDR}/1.0/containers/foo" | grep 403

  # Test unprivileged container publish
  mercury publish bar --alias=foo-image prop1=val1
  mercury image show foo-image | grep val1
  curl -k -s --cert "${APOLLO_CONF}/client3.crt" --key "${APOLLO_CONF}/client3.key" -X GET "https://${APOLLO_ADDR}/1.0/images" | grep "/1.0/images/" && false
  mercury image delete foo-image

  # Test container publish with existing alias
  mercury publish bar --alias=foo-image --alias=foo-image2
  mercury launch testimage baz
  # change the container filesystem so the resulting image is different
  mercury exec baz touch /somefile
  mercury stop baz
  # publishing another image with same alias doesn't fail
  mercury publish baz --alias=foo-image
  mercury delete baz
  mercury image delete foo-image foo-image2

  # Test image compression on publish
  mercury publish bar --alias=foo-image-compressed --compression=bzip2 prop=val1
  mercury image show foo-image-compressed | grep val1
  curl -k -s --cert "${APOLLO_CONF}/client3.crt" --key "${APOLLO_CONF}/client3.key" -X GET "https://${APOLLO_ADDR}/1.0/images" | grep "/1.0/images/" && false
  mercury image delete foo-image-compressed


  # Test privileged container publish
  mercury profile create priv
  mercury profile set priv security.privileged true
  mercury init testimage barpriv -p default -p priv
  mercury publish barpriv --alias=foo-image prop1=val1
  mercury image show foo-image | grep val1
  curl -k -s --cert "${APOLLO_CONF}/client3.crt" --key "${APOLLO_CONF}/client3.key" -X GET "https://${APOLLO_ADDR}/1.0/images" | grep "/1.0/images/" && false
  mercury image delete foo-image
  mercury delete barpriv
  mercury profile delete priv

  # Test that containers without metadata.yaml are published successfully.
  # Note that this quick hack won't work for LVM, since it doesn't always mount
  # the container's filesystem. That's ok though: the logic we're trying to
  # test here is independent of storage backend, so running it for just one
  # backend (or all non-lvm backends) is enough.
  if [ "$apollo_backend" = "lvm" ]; then
    mercury init testimage nometadata
    rm -f "${APOLLO_DIR}/containers/nometadata/metadata.yaml"
    mercury publish nometadata --alias=nometadata-image
    mercury image delete nometadata-image
    mercury delete nometadata
  fi

  # Test public images
  mercury publish --public bar --alias=foo-image2
  curl -k -s --cert "${APOLLO_CONF}/client3.crt" --key "${APOLLO_CONF}/client3.key" -X GET "https://${APOLLO_ADDR}/1.0/images" | grep "/1.0/images/"
  mercury image delete foo-image2

  # Test invalid container names
  ! mercury init testimage -abc
  ! mercury init testimage abc-
  ! mercury init testimage 1234
  ! mercury init testimage 12test
  ! mercury init testimage a_b_c
  ! mercury init testimage aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  # Test snapshot publish
  mercury snapshot bar
  mercury publish bar/snap0 --alias foo
  mercury init foo bar2
  mercury list | grep bar2
  mercury delete bar2
  mercury image delete foo

  # Test alias support
  cp "${APOLLO_CONF}/config.yml" "${APOLLO_CONF}/config.yml.bak"

  #   1. Basic built-in alias functionality
  [ "$(mercury ls)" = "$(mercury list)" ]
  #   2. Basic user-defined alias functionality
  printf "aliases:\n  l: list\n" >> "${APOLLO_CONF}/config.yml"
  [ "$(mercury l)" = "$(mercury list)" ]
  #   3. Built-in aliases and user-defined aliases can coexist
  [ "$(mercury ls)" = "$(mercury l)" ]
  #   4. Multi-argument alias keys and values
  printf "  i ls: image list\n" >> "${APOLLO_CONF}/config.yml"
  [ "$(mercury i ls)" = "$(mercury image list)" ]
  #   5. Aliases where len(keys) != len(values) (expansion/contraction of number of arguments)
  printf "  ils: image list\n  container ls: list\n" >> "${APOLLO_CONF}/config.yml"
  [ "$(mercury ils)" = "$(mercury image list)" ]
  [ "$(mercury container ls)" = "$(mercury list)" ]
  #   6. User-defined aliases override built-in aliases
  printf "  cp: list\n" >> "${APOLLO_CONF}/config.yml"
  [ "$(mercury ls)" = "$(mercury cp)" ]
  #   7. User-defined aliases override commands and don't recurse
  mercury init testimage foo
  MERCURY_CONFIG_SHOW=$(mercury config show foo --expanded)
  printf "  config show: config show --expanded\n" >> "${APOLLO_CONF}/config.yml"
  [ "$(mercury config show foo)" = "$MERCURY_CONFIG_SHOW" ]
  mercury delete foo

  # Restore the config to remove the aliases
  mv "${APOLLO_CONF}/config.yml.bak" "${APOLLO_CONF}/config.yml"

  # Delete the bar container we've used for several tests
  mercury delete bar

  # mercury delete should also delete all snapshots of bar
  [ ! -d "${APOLLO_DIR}/snapshots/bar" ]

  # Test randomly named container creation
  mercury launch testimage
  RDNAME=$(mercury list | tail -n2 | grep ^\| | awk '{print $2}')
  mercury delete -f "${RDNAME}"

  # Test "nonetype" container creation
  wait_for "${APOLLO_ADDR}" my_curl -X POST "https://${APOLLO_ADDR}/1.0/containers" \
        -d "{\"name\":\"nonetype\",\"source\":{\"type\":\"none\"}}"
  mercury delete nonetype

  # Test "nonetype" container creation with an MERCURY config
  wait_for "${APOLLO_ADDR}" my_curl -X POST "https://${APOLLO_ADDR}/1.0/containers" \
        -d "{\"name\":\"configtest\",\"config\":{\"raw.mercury\":\"mercury.hook.clone=/bin/true\"},\"source\":{\"type\":\"none\"}}"
  # shellcheck disable=SC2102
  [ "$(my_curl "https://${APOLLO_ADDR}/1.0/containers/configtest" | jq -r .metadata.config[\"raw.mercury\"])" = "mercury.hook.clone=/bin/true" ]
  mercury delete configtest

  # Test activateifneeded/shutdown
  APOLLO_ACTIVATION_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO_ACTIVATION_DIR}"
  spawn_apollo "${APOLLO_ACTIVATION_DIR}" true
  (
    set -e
    # shellcheck disable=SC2030
    APOLLO_DIR=${APOLLO_ACTIVATION_DIR}
    ensure_import_testimage
    apollo activateifneeded --debug 2>&1 | grep -q "Daemon has core.https_address set, activating..."
    mercury config unset core.https_address --force-local
    apollo activateifneeded --debug 2>&1 | grep -q -v "activating..."
    mercury init testimage autostart --force-local
    apollo activateifneeded --debug 2>&1 | grep -q -v "activating..."
    mercury config set autostart boot.autostart true --force-local
    apollo activateifneeded --debug 2>&1 | grep -q "Daemon has auto-started containers, activating..."

    mercury config unset autostart boot.autostart --force-local
    apollo activateifneeded --debug 2>&1 | grep -q -v "activating..."

    mercury start autostart --force-local
    PID=$(mercury info autostart --force-local | grep ^Pid | awk '{print $2}')
    shutdown_apollo "${APOLLO_DIR}"
    [ -d "/proc/${PID}" ] && false

    apollo activateifneeded --debug 2>&1 | grep -q "Daemon has auto-started containers, activating..."

    # shellcheck disable=SC2031
    respawn_apollo "${APOLLO_DIR}"

    mercury list --force-local autostart | grep -q RUNNING

    mercury delete autostart --force --force-local
  )
  # shellcheck disable=SC2031
  APOLLO_DIR=${APOLLO_DIR}
  kill_apollo "${APOLLO_ACTIVATION_DIR}"

  # Create and start a container
  mercury launch testimage foo
  mercury list | grep foo | grep RUNNING
  mercury stop foo --force  # stop is hanging

  # cycle it a few times
  mercury start foo
  mac1=$(mercury exec foo cat /sys/class/net/eth0/address)
  mercury stop foo --force # stop is hanging
  mercury start foo
  mac2=$(mercury exec foo cat /sys/class/net/eth0/address)

  if [ -n "${mac1}" ] && [ -n "${mac2}" ] && [ "${mac1}" != "${mac2}" ]; then
    echo "==> MAC addresses didn't match across restarts (${mac1} vs ${mac2})"
    false
  fi

  # Test instance types
  mercury launch testimage test-limits -t c0.5-m0.2
  [ "$(mercury config get test-limits limits.cpu)" = "1" ]
  [ "$(mercury config get test-limits limits.cpu.allowance)" = "50%" ]
  [ "$(mercury config get test-limits limits.memory)" = "204MB" ]
  mercury delete -f test-limits

  # Test last_used_at field is working properly
  mercury init testimage last-used-at-test
  mercury list last-used-at-test  --format json | jq -r '.[].last_used_at' | grep '1970-01-01T00:00:00Z'
  mercury start last-used-at-test
  mercury list last-used-at-test  --format json | jq -r '.[].last_used_at' | grep -v '1970-01-01T00:00:00Z'
  mercury delete last-used-at-test --force

  # check that we can set the environment
  mercury exec foo pwd | grep /root
  mercury exec --env BEST_BAND=meshuggah foo env | grep meshuggah
  mercury exec foo ip link show | grep eth0

  # check that we can get the return code for a non- wait-for-websocket exec
  op=$(my_curl -X POST "https://${APOLLO_ADDR}/1.0/containers/foo/exec" -d '{"command": ["sleep", "1"], "environment": {}, "wait-for-websocket": false, "interactive": false}' | jq -r .operation)
  [ "$(my_curl "https://${APOLLO_ADDR}${op}/wait" | jq -r .metadata.metadata.return)" != "null" ]

  # test file transfer
  echo abc > "${APOLLO_DIR}/in"

  mercury file push "${APOLLO_DIR}/in" foo/root/
  mercury exec foo /bin/cat /root/in | grep abc
  mercury exec foo -- /bin/rm -f root/in

  mercury file push "${APOLLO_DIR}/in" foo/root/in1
  mercury exec foo /bin/cat /root/in1 | grep abc
  mercury exec foo -- /bin/rm -f root/in1

  # test mercury file edit doesn't change target file's owner and permissions
  echo "content" | mercury file push - foo/tmp/edit_test
  mercury exec foo -- chown 55.55 /tmp/edit_test
  mercury exec foo -- chmod 555 /tmp/edit_test
  echo "new content" | mercury file edit foo/tmp/edit_test
  [ "$(mercury exec foo -- cat /tmp/edit_test)" = "new content" ]
  [ "$(mercury exec foo -- stat -c \"%u %g %a\" /tmp/edit_test)" = "55 55 555" ]

  # make sure stdin is chowned to our container root uid (Issue #590)
  [ -t 0 ] && [ -t 1 ] && mercury exec foo -- chown 1000:1000 /proc/self/fd/0

  echo foo | mercury exec foo tee /tmp/foo

  # Detect regressions/hangs in exec
  sum=$(ps aux | tee "${APOLLO_DIR}/out" | mercury exec foo md5sum | cut -d' ' -f1)
  [ "${sum}" = "$(md5sum "${APOLLO_DIR}/out" | cut -d' ' -f1)" ]
  rm "${APOLLO_DIR}/out"

  # FIXME: make this backend agnostic
  if [ "$apollo_backend" = "dir" ]; then
    content=$(cat "${APOLLO_DIR}/containers/foo/rootfs/tmp/foo")
    [ "${content}" = "foo" ]
  fi

  mercury launch testimage deleterunning
  my_curl -X DELETE "https://${APOLLO_ADDR}/1.0/containers/deleterunning" | grep "container is running"
  mercury delete deleterunning -f

  # cleanup
  mercury delete foo -f

  if [ -e /sys/module/apparmor/ ]; then
    # check that an apparmor profile is created for this container, that it is
    # unloaded on stop, and that it is deleted when the container is deleted
    mercury launch testimage apollo-apparmor-test

    MAJOR=0
    MINOR=0
    if [ -f /sys/kernel/security/apparmor/features/domain/version ]; then
      MAJOR=$(awk -F. '{print $1}' < /sys/kernel/security/apparmor/features/domain/version)
      MINOR=$(awk -F. '{print $2}' < /sys/kernel/security/apparmor/features/domain/version)
    fi

    if [ "${MAJOR}" -gt "1" ] || ([ "${MAJOR}" = "1" ] && [ "${MINOR}" -ge "2" ]); then
      aa_namespace="apollo-apollo-apparmor-test_<$(echo "${APOLLO_DIR}" | sed -e 's/\//-/g' -e 's/^.//')>"
      aa-status | grep ":${aa_namespace}://unconfined"
      mercury stop apollo-apparmor-test --force
      ! aa-status | grep -q ":${aa_namespace}:"
    else
      aa-status | grep "apollo-apollo-apparmor-test_<${APOLLO_DIR}>"
      mercury stop apollo-apparmor-test --force
      ! aa-status | grep -q "apollo-apollo-apparmor-test_<${APOLLO_DIR}>"
    fi
    mercury delete apollo-apparmor-test
    [ ! -f "${APOLLO_DIR}/security/apparmor/profiles/apollo-apollo-apparmor-test" ]
  else
    echo "==> SKIP: apparmor tests (missing kernel support)"
  fi

  mercury launch testimage apollo-seccomp-test
  init=$(mercury info apollo-seccomp-test | grep Pid | cut -f2 -d" ")
  [ "$(grep Seccomp "/proc/${init}/status" | cut -f2)" -eq "2" ]
  mercury stop --force apollo-seccomp-test
  mercury config set apollo-seccomp-test security.syscalls.blacklist_default false
  mercury start apollo-seccomp-test
  init=$(mercury info apollo-seccomp-test | grep Pid | cut -f2 -d" ")
  [ "$(grep Seccomp "/proc/${init}/status" | cut -f2)" -eq "0" ]
  mercury delete --force apollo-seccomp-test

  # make sure that privileged containers are not world-readable
  mercury profile create unconfined
  mercury profile set unconfined security.privileged true
  mercury init testimage foo2 -p unconfined -s "apollotest-$(basename "${APOLLO_DIR}")"
  [ "$(stat -L -c "%a" "${APOLLO_DIR}/containers/foo2")" = "700" ]
  mercury delete foo2
  mercury profile delete unconfined

  # Test boot.host_shutdown_timeout config setting
  mercury init testimage configtest --config boot.host_shutdown_timeout=45
  [ "$(mercury config get configtest boot.host_shutdown_timeout)" -eq 45 ]
  mercury config set configtest boot.host_shutdown_timeout 15
  [ "$(mercury config get configtest boot.host_shutdown_timeout)" -eq 15 ]
  mercury delete configtest

  # Test deleting multiple images
  # Start 3 containers to create 3 different images
  mercury launch testimage c1
  mercury launch testimage c2
  mercury launch testimage c3
  mercury exec c1 -- touch /tmp/c1
  mercury exec c2 -- touch /tmp/c2
  mercury exec c3 -- touch /tmp/c3
  mercury publish --force c1 --alias=image1
  mercury publish --force c2 --alias=image2
  mercury publish --force c3 --alias=image3
  # Delete multiple images with mercury delete and confirm they're deleted
  mercury image delete local:image1 local:image2 local:image3
  ! mercury image list | grep -q image1
  ! mercury image list | grep -q image2
  ! mercury image list | grep -q image3
  # Cleanup the containers
  mercury delete --force c1 c2 c3

  # Ephemeral
  mercury launch testimage foo -e

  OLD_INIT=$(mercury info foo | grep ^Pid)
  mercury exec foo reboot || true

  REBOOTED="false"

  # shellcheck disable=SC2034
  for i in $(seq 20); do
    NEW_INIT=$(mercury info foo | grep ^Pid || true)

    if [ -n "${NEW_INIT}" ] && [ "${OLD_INIT}" != "${NEW_INIT}" ]; then
      REBOOTED="true"
      break
    fi

    sleep 0.5
  done

  [ "${REBOOTED}" = "true" ]

  # Workaround for MERCURY bug which causes APOLLO to double-start containers
  # on reboot
  sleep 2

  mercury stop foo --force || true
  ! mercury list | grep -q foo
}
