test_filemanip() {
  # Workaround for shellcheck getting confused by "cd"
  set -e
  ensure_import_testimage
  ensure_has_localhost_remote "${APOLLO_ADDR}"

  echo "test" > "${TEST_DIR}"/filemanip

  mercury launch testimage filemanip
  mercury exec filemanip -- ln -s /tmp/ /tmp/outside
  mercury file push "${TEST_DIR}"/filemanip filemanip/tmp/outside/

  [ ! -f /tmp/filemanip ]
  mercury exec filemanip -- ls /tmp/filemanip

  # missing files should return 404
  err=$(my_curl -o /dev/null -w "%{http_code}" -X GET "https://${APOLLO_ADDR}/1.0/containers/filemanip/files?path=/tmp/foo")
  [ "${err}" -eq "404" ]

  # mercury {push|pull} -r
  mkdir "${TEST_DIR}"/source
  mkdir "${TEST_DIR}"/source/another_level
  chown 1000:1000 "${TEST_DIR}"/source/another_level
  echo "foo" > "${TEST_DIR}"/source/foo
  echo "bar" > "${TEST_DIR}"/source/bar
  ln -s bar "${TEST_DIR}"/source/baz

  mercury file push -p -r "${TEST_DIR}"/source filemanip/tmp/ptest

  [ "$(mercury exec filemanip -- stat -c "%u" /tmp/ptest/source)" = "$(id -u)" ]
  [ "$(mercury exec filemanip -- stat -c "%g" /tmp/ptest/source)" = "$(id -g)" ]
  [ "$(mercury exec filemanip -- stat -c "%u" /tmp/ptest/source/another_level)" = "1000" ]
  [ "$(mercury exec filemanip -- stat -c "%g" /tmp/ptest/source/another_level)" = "1000" ]
  [ "$(mercury exec filemanip -- stat -c "%a" /tmp/ptest/source)" = "755" ]
  [ "$(mercury exec filemanip -- readlink /tmp/ptest/source/baz)" = "bar" ]

  mercury exec filemanip -- rm -rf /tmp/ptest/source

  # Test pushing/pulling a file with spaces
  echo "foo" > "${TEST_DIR}/source/file with spaces"

  mercury file push -p -r "${TEST_DIR}"/source filemanip/tmp/ptest
  mercury exec filemanip -- find /tmp/ptest/source | grep -q "file with spaces"
  rm -rf "${TEST_DIR}/source/file with spaces"

  mercury file pull -p -r filemanip/tmp/ptest "${TEST_DIR}/dest"
  find "${TEST_DIR}/dest/" | grep "file with spaces"
  rm -rf "${TEST_DIR}/dest"

  # Check that file permissions are not applied to intermediate directories

  mercury file push -p --mode=400 "${TEST_DIR}"/source/foo \
      filemanip/tmp/ptest/d1/d2/foo

  [ "$(mercury exec filemanip -- stat -c "%a" /tmp/ptest/d1)" = "750" ]
  [ "$(mercury exec filemanip -- stat -c "%a" /tmp/ptest/d1/d2)" = "750" ]

  mercury exec filemanip -- rm -rf /tmp/ptest/d1

  # Special case where we are in the same directory as the one we are currently
  # created.
  oldcwd=$(pwd)
  cd "${TEST_DIR}"

  mercury file push -r source filemanip/tmp/ptest

  [ "$(mercury exec filemanip -- stat -c "%u" /tmp/ptest/source)" = "$(id -u)" ]
  [ "$(mercury exec filemanip -- stat -c "%g" /tmp/ptest/source)" = "$(id -g)" ]
  [ "$(mercury exec filemanip -- stat -c "%a" /tmp/ptest/source)" = "755" ]

  mercury exec filemanip -- rm -rf /tmp/ptest/source

  # Special case where we are in the same directory as the one we are currently
  # created.
  cd source

  mercury file push -r ./ filemanip/tmp/ptest

  [ "$(mercury exec filemanip -- stat -c "%u" /tmp/ptest/another_level)" = "1000" ]
  [ "$(mercury exec filemanip -- stat -c "%g" /tmp/ptest/another_level)" = "1000" ]

  mercury exec filemanip -- rm -rf /tmp/ptest/*

  mercury file push -r ../source filemanip/tmp/ptest

  [ "$(mercury exec filemanip -- stat -c "%u" /tmp/ptest/source)" = "$(id -u)" ]
  [ "$(mercury exec filemanip -- stat -c "%g" /tmp/ptest/source)" = "$(id -g)" ]
  [ "$(mercury exec filemanip -- stat -c "%a" /tmp/ptest/source)" = "755" ]

  # Switch back to old working directory.
  cd "${oldcwd}"

  mkdir "${TEST_DIR}"/dest
  mercury file pull -r filemanip/tmp/ptest/source "${TEST_DIR}"/dest

  [ "$(cat "${TEST_DIR}"/dest/source/foo)" = "foo" ]
  [ "$(cat "${TEST_DIR}"/dest/source/bar)" = "bar" ]

  [ "$(stat -c "%u" "${TEST_DIR}"/dest/source)" = "$(id -u)" ]
  [ "$(stat -c "%g" "${TEST_DIR}"/dest/source)" = "$(id -g)" ]
  [ "$(stat -c "%a" "${TEST_DIR}"/dest/source)" = "755" ]

  mercury file push -p "${TEST_DIR}"/source/foo filemanip/tmp/this/is/a/nonexistent/directory/
  mercury file pull filemanip/tmp/this/is/a/nonexistent/directory/foo "${TEST_DIR}"
  [ "$(cat "${TEST_DIR}"/foo)" = "foo" ]

  mercury file push -p "${TEST_DIR}"/source/foo filemanip/.
  [ "$(mercury exec filemanip cat /foo)" = "foo" ]

  mercury file push -p "${TEST_DIR}"/source/foo filemanip/A/B/C/D/
  [ "$(mercury exec filemanip cat /A/B/C/D/foo)" = "foo" ]

  mercury delete filemanip -f

  if [ "$(storage_backend "$APOLLO_DIR")" != "lvm" ]; then
    mercury launch testimage idmap -c "raw.idmap=\"both 0 0\""
    [ "$(stat -c %u "${APOLLO_DIR}/containers/idmap/rootfs")" = "0" ]
    mercury delete idmap --force
  fi
}
