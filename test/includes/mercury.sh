# mercury CLI related test helpers.

mercury() {
    MERCURY_LOCAL=1 mercury_remote "$@"
}

mercury_remote() {
    set +x
    # shellcheck disable=SC2039
    local injected cmd arg

    injected=0
    cmd=$(which mercury)

    # shellcheck disable=SC2048,SC2068
    for arg in $@; do
        if [ "${arg}" = "--" ]; then
            injected=1
            cmd="${cmd} ${DEBUG:-}"
            [ -n "${MERCURY_LOCAL}" ] && cmd="${cmd} --force-local"
            cmd="${cmd} --"
        elif [ "${arg}" = "--force-local" ]; then
            continue
        else
            cmd="${cmd} \"${arg}\""
        fi
    done

    if [ "${injected}" = "0" ]; then
        cmd="${cmd} ${DEBUG-}"
    fi
    if [ -n "${DEBUG:-}" ]; then
        set -x
    fi
    eval "${cmd}"
}

gen_cert() {
    # Temporarily move the existing cert to trick MERCURY into generating a
    # second cert.  MERCURY will only generate a cert when adding a remote
    # server with a HTTPS scheme.  The remote server URL just needs to
    # be syntactically correct to get past initial checks; in fact, we
    # don't want it to succeed, that way we don't have to delete it later.
    [ -f "${APOLLO_CONF}/${1}.crt" ] && return
    mv "${APOLLO_CONF}/client.crt" "${APOLLO_CONF}/client.crt.bak"
    mv "${APOLLO_CONF}/client.key" "${APOLLO_CONF}/client.key.bak"
    echo y | mercury_remote remote add "$(uuidgen)" https://0.0.0.0 || true
    mv "${APOLLO_CONF}/client.crt" "${APOLLO_CONF}/${1}.crt"
    mv "${APOLLO_CONF}/client.key" "${APOLLO_CONF}/${1}.key"
    mv "${APOLLO_CONF}/client.crt.bak" "${APOLLO_CONF}/client.crt"
    mv "${APOLLO_CONF}/client.key.bak" "${APOLLO_CONF}/client.key"
}
