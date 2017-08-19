# APOLLO-related test helpers.

spawn_apollo() {
    set +x
    # APOLLO_DIR is local here because since $(mercury) is actually a function, it
    # overwrites the environment and we would lose APOLLO_DIR's value otherwise.

    # shellcheck disable=2039
    local APOLLO_DIR apollodir apollo_backend

    apollodir=${1}
    shift

    storage=${1}
    shift

    # shellcheck disable=SC2153
    if [ "$APOLLO_BACKEND" = "random" ]; then
        apollo_backend="$(random_storage_backend)"
    else
        apollo_backend="$APOLLO_BACKEND"
    fi

    if [ "${APOLLO_BACKEND}" = "ceph" ] && [ -z "${APOLLO_CEPH_CLUSTER:-}" ]; then
        echo "A cluster name must be specified when using the CEPH driver." >&2
        exit 1
    fi

    # Copy pre generated Certs
    cp deps/server.crt "${apollodir}"
    cp deps/server.key "${apollodir}"

    # setup storage
    "$apollo_backend"_setup "${apollodir}"
    echo "$apollo_backend" > "${apollodir}/apollo.backend"

    echo "==> Spawning apollo in ${apollodir}"
    # shellcheck disable=SC2086
    APOLLO_DIR="${apollodir}" apollo --logfile "${apollodir}/apollo.log" ${DEBUG-} "$@" 2>&1 &
    APOLLO_PID=$!
    echo "${APOLLO_PID}" > "${apollodir}/apollo.pid"
    # shellcheck disable=SC2153
    echo "${apollodir}" >> "${TEST_DIR}/daemons"
    echo "==> Spawned APOLLO (PID is ${APOLLO_PID})"

    echo "==> Confirming apollo is responsive"
    APOLLO_DIR="${apollodir}" apollo waitready --timeout=300

    echo "==> Binding to network"
    # shellcheck disable=SC2034
    for i in $(seq 10); do
        addr="127.0.0.1:$(local_tcp_port)"
        APOLLO_DIR="${apollodir}" mercury config set core.https_address "${addr}" || continue
        echo "${addr}" > "${apollodir}/apollo.addr"
        echo "==> Bound to ${addr}"
        break
    done

    echo "==> Setting trust password"
    APOLLO_DIR="${apollodir}" mercury config set core.trust_password foo
    if [ -n "${DEBUG:-}" ]; then
        set -x
    fi

    echo "==> Setting up networking"
    APOLLO_DIR="${apollodir}" mercury profile device add default eth0 nic nictype=p2p name=eth0

    if [ "${storage}" = true ]; then
        echo "==> Configuring storage backend"
        "$apollo_backend"_configure "${apollodir}"
    fi
}

respawn_apollo() {
    set +x
    # APOLLO_DIR is local here because since $(mercury) is actually a function, it
    # overwrites the environment and we would lose APOLLO_DIR's value otherwise.

    # shellcheck disable=2039
    local APOLLO_DIR

    apollodir=${1}
    shift

    echo "==> Spawning apollo in ${apollodir}"
    # shellcheck disable=SC2086
    APOLLO_DIR="${apollodir}" apollo --logfile "${apollodir}/apollo.log" ${DEBUG-} "$@" 2>&1 &
    APOLLO_PID=$!
    echo "${APOLLO_PID}" > "${apollodir}/apollo.pid"
    echo "==> Spawned APOLLO (PID is ${APOLLO_PID})"

    echo "==> Confirming apollo is responsive"
    APOLLO_DIR="${apollodir}" apollo waitready --timeout=300
}

kill_apollo() {
    # APOLLO_DIR is local here because since $(mercury) is actually a function, it
    # overwrites the environment and we would lose APOLLO_DIR's value otherwise.

    # shellcheck disable=2039
    local APOLLO_DIR daemon_dir daemon_pid check_leftovers apollo_backend

    daemon_dir=${1}
    APOLLO_DIR=${daemon_dir}
    daemon_pid=$(cat "${daemon_dir}/apollo.pid")
    check_leftovers="false"
    apollo_backend=$(storage_backend "$daemon_dir")
    echo "==> Killing APOLLO at ${daemon_dir}"

    if [ -e "${daemon_dir}/unix.socket" ]; then
        # Delete all containers
        echo "==> Deleting all containers"
        for container in $(mercury list --fast --force-local | tail -n+3 | grep "^| " | cut -d' ' -f2); do
            mercury delete "${container}" --force-local -f || true
        done

        # Delete all images
        echo "==> Deleting all images"
        for image in $(mercury image list --force-local | tail -n+3 | grep "^| " | cut -d'|' -f3 | sed "s/^ //g"); do
            mercury image delete "${image}" --force-local || true
        done

        # Delete all networks
        echo "==> Deleting all networks"
        for network in $(mercury network list --force-local | grep YES | grep "^| " | cut -d' ' -f2); do
            mercury network delete "${network}" --force-local || true
        done

        # Delete all profiles
        echo "==> Deleting all profiles"
        for profile in $(mercury profile list --force-local | tail -n+3 | grep "^| " | cut -d' ' -f2); do
            mercury profile delete "${profile}" --force-local || true
        done

        echo "==> Deleting all storage pools"
        for storage in $(mercury storage list --force-local | tail -n+3 | grep "^| " | cut -d' ' -f2); do
            mercury storage delete "${storage}" --force-local || true
        done

        echo "==> Checking for locked DB tables"
        for table in $(echo .tables | sqlite3 "${daemon_dir}/apollo.db"); do
            echo "SELECT * FROM ${table};" | sqlite3 "${daemon_dir}/apollo.db" >/dev/null
        done

        # Kill the daemon
        apollo shutdown || kill -9 "${daemon_pid}" 2>/dev/null || true

        # Cleanup shmounts (needed due to the forceful kill)
        find "${daemon_dir}" -name shmounts -exec "umount" "-l" "{}" \; >/dev/null 2>&1 || true
        find "${daemon_dir}" -name devapollo -exec "umount" "-l" "{}" \; >/dev/null 2>&1 || true

        check_leftovers="true"
    fi

    if [ -n "${APOLLO_LOGS:-}" ]; then
        echo "==> Copying the logs"
        mkdir -p "${APOLLO_LOGS}/${daemon_pid}"
        cp -R "${daemon_dir}/logs/" "${APOLLO_LOGS}/${daemon_pid}/"
        cp "${daemon_dir}/apollo.log" "${APOLLO_LOGS}/${daemon_pid}/"
    fi

    if [ "${check_leftovers}" = "true" ]; then
        echo "==> Checking for leftover files"
        rm -f "${daemon_dir}/containers/mercury-monitord.log"
        rm -f "${daemon_dir}/security/apparmor/cache/.features"
        check_empty "${daemon_dir}/containers/"
        check_empty "${daemon_dir}/devices/"
        check_empty "${daemon_dir}/images/"
        # FIXME: Once container logging rework is done, uncomment
        # check_empty "${daemon_dir}/logs/"
        check_empty "${daemon_dir}/security/apparmor/cache/"
        check_empty "${daemon_dir}/security/apparmor/profiles/"
        check_empty "${daemon_dir}/security/seccomp/"
        check_empty "${daemon_dir}/shmounts/"
        check_empty "${daemon_dir}/snapshots/"

        echo "==> Checking for leftover DB entries"
        check_empty_table "${daemon_dir}/apollo.db" "containers"
        check_empty_table "${daemon_dir}/apollo.db" "containers_config"
        check_empty_table "${daemon_dir}/apollo.db" "containers_devices"
        check_empty_table "${daemon_dir}/apollo.db" "containers_devices_config"
        check_empty_table "${daemon_dir}/apollo.db" "containers_profiles"
        check_empty_table "${daemon_dir}/apollo.db" "networks"
        check_empty_table "${daemon_dir}/apollo.db" "networks_config"
        check_empty_table "${daemon_dir}/apollo.db" "images"
        check_empty_table "${daemon_dir}/apollo.db" "images_aliases"
        check_empty_table "${daemon_dir}/apollo.db" "images_properties"
        check_empty_table "${daemon_dir}/apollo.db" "images_source"
        check_empty_table "${daemon_dir}/apollo.db" "profiles"
        check_empty_table "${daemon_dir}/apollo.db" "profiles_config"
        check_empty_table "${daemon_dir}/apollo.db" "profiles_devices"
        check_empty_table "${daemon_dir}/apollo.db" "profiles_devices_config"
        check_empty_table "${daemon_dir}/apollo.db" "storage_pools"
        check_empty_table "${daemon_dir}/apollo.db" "storage_pools_config"
        check_empty_table "${daemon_dir}/apollo.db" "storage_volumes"
        check_empty_table "${daemon_dir}/apollo.db" "storage_volumes_config"
    fi

    # teardown storage
    "$apollo_backend"_teardown "${daemon_dir}"

    # Wipe the daemon directory
    wipe "${daemon_dir}"

    # Remove the daemon from the list
    sed "\|^${daemon_dir}|d" -i "${TEST_DIR}/daemons"
}

shutdown_apollo() {
    # APOLLO_DIR is local here because since $(mercury) is actually a function, it
    # overwrites the environment and we would lose APOLLO_DIR's value otherwise.

    # shellcheck disable=2039
    local APOLLO_DIR

    daemon_dir=${1}
    # shellcheck disable=2034
    APOLLO_DIR=${daemon_dir}
    daemon_pid=$(cat "${daemon_dir}/apollo.pid")
    echo "==> Killing APOLLO at ${daemon_dir}"

    # Kill the daemon
    apollo shutdown || kill -9 "${daemon_pid}" 2>/dev/null || true
}

wait_for() {
    # shellcheck disable=SC2039
    local addr op

    addr=${1}
    shift
    op=$("$@" | jq -r .operation)
    my_curl "https://${addr}${op}/wait"
}

wipe() {
    if which btrfs >/dev/null 2>&1; then
        rm -Rf "${1}" 2>/dev/null || true
        if [ -d "${1}" ]; then
            find "${1}" | tac | xargs btrfs subvolume delete >/dev/null 2>&1 || true
        fi
    fi

    # shellcheck disable=SC2039
    local pid
    # shellcheck disable=SC2009
    ps aux | grep mercury-monitord | grep "${1}" | awk '{print $2}' | while read -r pid; do
        kill -9 "${pid}" || true
    done

    if mountpoint -q "${1}"; then
        umount "${1}"
    fi

    rm -Rf "${1}"
}

# Kill and cleanup APOLLO instances and related resources
cleanup_apollos() {
    # shellcheck disable=SC2039
    local test_dir daemon_dir
    test_dir="$1"

    # Kill all APOLLO instances
    while read -r daemon_dir; do
        kill_apollo "${daemon_dir}"
    done < "${test_dir}/daemons"

    # Cleanup leftover networks
    # shellcheck disable=SC2009
    ps aux | grep "interface=apollot$$ " | grep -v grep | awk '{print $2}' | while read -r line; do
        kill -9 "${line}"
    done
    if [ -e "/sys/class/net/apollot$$" ]; then
        ip link del apollot$$
    fi

    # Wipe the test environment
    wipe "$test_dir"

    umount_loops "$test_dir"
}
