test_concurrent() {
  if [ -z "${APOLLO_CONCURRENT:-}" ]; then
    echo "==> SKIP: APOLLO_CONCURRENT isn't set"
    return
  fi

  ensure_import_testimage

  spawn_container() {
    set -e

    name=concurrent-${1}

    mercury launch testimage "${name}"
    mercury info "${name}" | grep Running
    echo abc | mercury exec "${name}" -- cat | grep abc
    mercury stop "${name}" --force
    mercury delete "${name}"
  }

  PIDS=""

  for id in $(seq $(($(find /sys/bus/cpu/devices/ -type l | wc -l)*8))); do
    spawn_container "${id}" 2>&1 | tee "${APOLLO_DIR}/mercury-${id}.out" &
    PIDS="${PIDS} $!"
  done

  for pid in ${PIDS}; do
    wait "${pid}"
  done

  ! mercury list | grep -q concurrent
}
