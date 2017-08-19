test_cpu_profiling() {
  APOLLO3_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO3_DIR}"
  spawn_apollo "${APOLLO3_DIR}" false --cpuprofile "${APOLLO3_DIR}/cpu.out"
  apollopid=$(cat "${APOLLO3_DIR}/apollo.pid")
  kill -TERM "${apollopid}"
  wait "${apollopid}" || true
  export PPROF_TMPDIR="${TEST_DIR}/pprof"
  echo top5 | go tool pprof "$(which apollo)" "${APOLLO3_DIR}/cpu.out"
  echo ""

  # Cleanup following manual kill
  rm -f "${APOLLO3_DIR}/unix.socket"
  find "${APOLLO3_DIR}" -name shmounts -exec "umount" "-l" "{}" \; >/dev/null 2>&1 || true

  kill_apollo "${APOLLO3_DIR}"
}

test_mem_profiling() {
  APOLLO4_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO4_DIR}"
  spawn_apollo "${APOLLO4_DIR}" false --memprofile "${APOLLO4_DIR}/mem"
  apollopid=$(cat "${APOLLO4_DIR}/apollo.pid")

  if [ -e "${APOLLO4_DIR}/mem" ]; then
    false
  fi

  kill -USR1 "${apollopid}"

  timeout=50
  while [ "${timeout}" != "0" ]; do
    [ -e "${APOLLO4_DIR}/mem" ] && break
    sleep 0.1
    timeout=$((timeout-1))
  done

  export PPROF_TMPDIR="${TEST_DIR}/pprof"
  echo top5 | go tool pprof "$(which apollo)" "${APOLLO4_DIR}/mem"
  echo ""

  kill_apollo "${APOLLO4_DIR}"
}
