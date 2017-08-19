test_remote_url() {
  # shellcheck disable=2153
  for url in "${APOLLO_ADDR}" "https://${APOLLO_ADDR}"; do
    mercury_remote remote add test "${url}" --accept-certificate --password foo
    mercury_remote finger test:
    mercury_remote config trust list | grep @ | awk '{print $2}' | while read -r line ; do
      mercury_remote config trust remove "\"${line}\""
    done
    mercury_remote remote remove test
  done

  # shellcheck disable=2153
  urls="${APOLLO_DIR}/unix.socket unix:${APOLLO_DIR}/unix.socket unix://${APOLLO_DIR}/unix.socket"
  if [ -z "${APOLLO_OFFLINE:-}" ]; then
    urls="images.linuxcontainers.org https://images.linuxcontainers.org ${urls}"
  fi

  for url in ${urls}; do
    mercury_remote remote add test "${url}"
    mercury_remote remote remove test
  done
}

test_remote_admin() {
  mercury_remote remote add badpass "${APOLLO_ADDR}" --accept-certificate --password bad || true
  ! mercury_remote list badpass:

  mercury_remote remote add localhost "${APOLLO_ADDR}" --accept-certificate --password foo
  mercury_remote remote list | grep 'localhost'

  mercury_remote remote set-default localhost
  [ "$(mercury_remote remote get-default)" = "localhost" ]

  mercury_remote remote rename localhost foo
  mercury_remote remote list | grep 'foo'
  mercury_remote remote list | grep -v 'localhost'
  [ "$(mercury_remote remote get-default)" = "foo" ]

  ! mercury_remote remote remove foo
  mercury_remote remote set-default local
  mercury_remote remote remove foo

  # This is a test for #91, we expect this to hang asking for a password if we
  # tried to re-add our cert.
  echo y | mercury_remote remote add localhost "${APOLLO_ADDR}"

  # we just re-add our cert under a different name to test the cert
  # manipulation mechanism.
  gen_cert client2

  # Test for #623
  mercury_remote remote add test-623 "${APOLLO_ADDR}" --accept-certificate --password foo

  # now re-add under a different alias
  mercury_remote config trust add "${APOLLO_CONF}/client2.crt"
  if [ "$(mercury_remote config trust list | wc -l)" -ne 7 ]; then
    echo "wrong number of certs"
    false
  fi

  # Check that we can add domains with valid certs without confirmation:

  # avoid default high port behind some proxies:
  if [ -z "${APOLLO_OFFLINE:-}" ]; then
    mercury_remote remote add images1 images.linuxcontainers.org
    mercury_remote remote add images2 images.linuxcontainers.org:443
  fi
}

test_remote_usage() {
  # shellcheck disable=2039
  local APOLLO2_DIR APOLLO2_ADDR
  APOLLO2_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO2_DIR}"
  spawn_apollo "${APOLLO2_DIR}" true
  APOLLO2_ADDR=$(cat "${APOLLO2_DIR}/apollo.addr")

  ensure_import_testimage
  ensure_has_localhost_remote "${APOLLO_ADDR}"

  mercury_remote remote add apollo2 "${APOLLO2_ADDR}" --accept-certificate --password foo

  # we need a public image on localhost

  mercury_remote image export localhost:testimage "${APOLLO_DIR}/foo"
  mercury_remote image delete localhost:testimage
  sum=$(sha256sum "${APOLLO_DIR}/foo" | cut -d' ' -f1)
  mercury_remote image import "${APOLLO_DIR}/foo" localhost: --public
  mercury_remote image alias create localhost:testimage "${sum}"

  mercury_remote image delete "apollo2:${sum}" || true

  mercury_remote image copy localhost:testimage apollo2: --copy-aliases --public
  mercury_remote image delete "localhost:${sum}"
  mercury_remote image copy "apollo2:${sum}" local: --copy-aliases --public
  mercury_remote image info localhost:testimage
  mercury_remote image delete "apollo2:${sum}"

  mercury_remote image copy "localhost:${sum}" apollo2:
  mercury_remote image delete "apollo2:${sum}"

  mercury_remote image copy "localhost:$(echo "${sum}" | colrm 3)" apollo2:
  mercury_remote image delete "apollo2:${sum}"

  # test a private image
  mercury_remote image copy "localhost:${sum}" apollo2:
  mercury_remote image delete "localhost:${sum}"
  mercury_remote init "apollo2:${sum}" localhost:c1
  mercury_remote delete localhost:c1

  mercury_remote image alias create localhost:testimage "${sum}"

  # test remote publish
  mercury_remote init testimage pub
  mercury_remote publish pub apollo2: --alias bar --public a=b
  mercury_remote image show apollo2:bar | grep -q "a: b"
  mercury_remote image show apollo2:bar | grep -q "public: true"
  ! mercury_remote image show bar
  mercury_remote delete pub

  # test spawn from public server
  mercury_remote remote add apollo2-public "${APOLLO2_ADDR}" --public --accept-certificate
  mercury_remote init apollo2-public:bar pub
  mercury_remote image delete apollo2:bar
  mercury_remote delete pub

  # Double launch to test if the image downloads only once.
  mercury_remote init localhost:testimage apollo2:c1 &
  C1PID=$!

  mercury_remote init localhost:testimage apollo2:c2
  mercury_remote delete apollo2:c2

  wait "${C1PID}"
  mercury_remote delete apollo2:c1

  # launch testimage stored on localhost as container c1 on apollo2
  mercury_remote launch localhost:testimage apollo2:c1

  # make sure it is running
  mercury_remote list apollo2: | grep c1 | grep RUNNING
  mercury_remote info apollo2:c1
  mercury_remote stop apollo2:c1 --force
  mercury_remote delete apollo2:c1

  # Test that local and public servers can be accessed without a client cert
  mv "${APOLLO_CONF}/client.crt" "${APOLLO_CONF}/client.crt.bak"
  mv "${APOLLO_CONF}/client.key" "${APOLLO_CONF}/client.key.bak"

  # testimage should still exist on the local server.
  mercury_remote image list local: | grep -q testimage

  # Skip the truly remote servers in offline mode.  There should always be
  # Ubuntu images in the results for the remote servers.
  if [ -z "${APOLLO_OFFLINE:-}" ]; then
    mercury_remote image list images: | grep -i -c ubuntu
    mercury_remote image list ubuntu: | grep -i -c ubuntu
  fi

  mv "${APOLLO_CONF}/client.crt.bak" "${APOLLO_CONF}/client.crt"
  mv "${APOLLO_CONF}/client.key.bak" "${APOLLO_CONF}/client.key"

  kill_apollo "$APOLLO2_DIR"
}
