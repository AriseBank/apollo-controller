test_concurrent_exec() {
  if [ -z "${APOLLO_CONCURRENT:-}" ]; then
    echo "==> SKIP: APOLLO_CONCURRENT isn't set"
    return
  fi

  ensure_import_testimage

  name=x1
  mercury launch testimage x1
  mercury list ${name} | grep RUNNING

  exec_container() {
    echo "abc${1}" | mercury exec "${name}" -- cat | grep abc
  }

  PIDS=""
  for i in $(seq 1 50); do
    exec_container "${i}" > "${APOLLO_DIR}/exec-${i}.out" 2>&1 &
    PIDS="${PIDS} $!"
  done

  for pid in ${PIDS}; do
    wait "${pid}"
  done

  mercury stop "${name}" --force
  mercury delete "${name}"
}
