test_server_config() {
  APOLLO_SERVERCONFIG_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  spawn_apollo "${APOLLO_SERVERCONFIG_DIR}" true

  ensure_has_localhost_remote "${APOLLO_ADDR}"
  mercury config set core.trust_password 123456

  config=$(mercury config show)
  echo "${config}" | grep -q "trust_password"
  echo "${config}" | grep -q -v "123456"

  mercury config unset core.trust_password
  mercury config show | grep -q -v "trust_password"

  # test untrusted server GET
  my_curl -X GET "https://$(cat "${APOLLO_SERVERCONFIG_DIR}/apollo.addr")/1.0" | grep -v -q environment
}
