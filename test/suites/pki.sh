test_pki() {
  if [ ! -d "/usr/share/easy-rsa/" ]; then
    echo "==> SKIP: The pki test requires easy-rsa to be installed"
    return
  fi

  # Setup the PKI
  cp -R /usr/share/easy-rsa "${TEST_DIR}/pki"
  (
    set -e
    cd "${TEST_DIR}/pki"
    ls
    # shellcheck disable=SC1091
    . ./vars
    ./clean-all
    ./pkitool --initca
    ./pkitool --server 127.0.0.1
    ./pkitool apollo-client
  )

  # Setup the daemon
  APOLLO5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO5_DIR}"
  cat "${TEST_DIR}/pki/keys/127.0.0.1.crt" "${TEST_DIR}/pki/keys/ca.crt" > "${APOLLO5_DIR}/server.crt"
  cp "${TEST_DIR}/pki/keys/127.0.0.1.key" "${APOLLO5_DIR}/server.key"
  cp "${TEST_DIR}/pki/keys/ca.crt" "${APOLLO5_DIR}/server.ca"
  spawn_apollo "${APOLLO5_DIR}" true
  APOLLO5_ADDR=$(cat "${APOLLO5_DIR}/apollo.addr")

  # Setup the client
  MERCURY5_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  cp "${TEST_DIR}/pki/keys/apollo-client.crt" "${MERCURY5_DIR}/client.crt"
  cp "${TEST_DIR}/pki/keys/apollo-client.key" "${MERCURY5_DIR}/client.key"
  cp "${TEST_DIR}/pki/keys/ca.crt" "${MERCURY5_DIR}/client.ca"

  # Confirm that a valid client certificate works
  (
    set -e
    export APOLLO_CONF=${MERCURY5_DIR}
    mercury_remote remote add pki-apollo "${APOLLO5_ADDR}" --accept-certificate --password=foo
    mercury_remote info pki-apollo:
  )

  # Confirm that a normal, non-PKI certificate doesn't
  ! mercury_remote remote add pki-apollo "${APOLLO5_ADDR}" --accept-certificate --password=foo

  kill_apollo "${APOLLO5_DIR}"
}
