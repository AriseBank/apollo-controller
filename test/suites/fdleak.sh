test_fdleak() {
  APOLLO_FDLEAK_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO_FDLEAK_DIR}"
  spawn_apollo "${APOLLO_FDLEAK_DIR}" true
  pid=$(cat "${APOLLO_FDLEAK_DIR}/apollo.pid")

  beforefds=$(/bin/ls "/proc/${pid}/fd" | wc -l)
  (
    set -e
    # shellcheck disable=SC2034
    APOLLO_DIR=${APOLLO_FDLEAK_DIR}

    ensure_import_testimage

    for i in $(seq 5); do
      mercury init "testimage leaktest${i}"
      mercury info "leaktest${i}"
      mercury start "leaktest${i}"
      mercury exec "leaktest${i}" -- ps -ef
      mercury stop "leaktest${i}" --force
      mercury delete "leaktest${i}"
    done

    sleep 5

    exit 0
  )
  afterfds=$(/bin/ls "/proc/${pid}/fd" | wc -l)
  leakedfds=$((afterfds - beforefds))

  bad=0
  # shellcheck disable=SC2015
  [ ${leakedfds} -gt 5 ] && bad=1 || true
  if [ ${bad} -eq 1 ]; then
    echo "${leakedfds} FDS leaked"
    ls "/proc/${pid}/fd" -al
    netstat -anp 2>&1 | grep "${pid}/"
    false
  fi

  kill_apollo "${APOLLO_FDLEAK_DIR}"
}
