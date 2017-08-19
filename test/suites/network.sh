test_network() {
  ensure_import_testimage
  ensure_has_localhost_remote "${APOLLO_ADDR}"

  mercury init testimage nettest

  # Standard bridge with random subnet and a bunch of options
  mercury network create apollot$$
  mercury network set apollot$$ dns.mode dynamic
  mercury network set apollot$$ dns.domain blah
  mercury network set apollot$$ ipv4.routing false
  mercury network set apollot$$ ipv6.routing false
  mercury network set apollot$$ ipv6.dhcp.stateful true
  mercury network delete apollot$$

  # edit network description
  mercury network create apollot$$
  mercury network show apollot$$ | sed 's/^description:.*/description: foo/' | mercury network edit apollot$$
  mercury network show apollot$$ | grep -q 'description: foo'
  mercury network delete apollot$$

  # Unconfigured bridge
  mercury network create apollot$$ ipv4.address=none ipv6.address=none
  mercury network delete apollot$$

  # Configured bridge with static assignment
  mercury network create apollot$$ dns.domain=test dns.mode=managed
  mercury network attach apollot$$ nettest eth0
  v4_addr="$(mercury network get apollot$$ ipv4.address | cut -d/ -f1)0"
  v6_addr="$(mercury network get apollot$$ ipv4.address | cut -d/ -f1)00"
  mercury config device set nettest eth0 ipv4.address "${v4_addr}"
  mercury config device set nettest eth0 ipv6.address "${v6_addr}"
  grep -q "${v4_addr}.*nettest" "${APOLLO_DIR}/networks/apollot$$/dnsmasq.hosts"
  grep -q "${v6_addr}.*nettest" "${APOLLO_DIR}/networks/apollot$$/dnsmasq.hosts"
  mercury start nettest

  SUCCESS=0
  # shellcheck disable=SC2034
  for i in $(seq 10); do
    mercury info nettest | grep -q fd42 && SUCCESS=1 && break
    sleep 1
  done

  [ "${SUCCESS}" = "0" ] && (echo "Container static IP wasn't applied" && false)

  mercury delete nettest -f
  mercury network delete apollot$$
}
