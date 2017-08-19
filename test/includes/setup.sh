# Test setup helper functions.

ensure_has_localhost_remote() {
    # shellcheck disable=SC2039
    local addr=${1}
    if ! mercury remote list | grep -q "localhost"; then
        mercury remote add localhost "https://${addr}" --accept-certificate --password foo
    fi
}

ensure_import_testimage() {
    if ! mercury image alias list | grep -q "^| testimage\s*|.*$"; then
        if [ -e "${APOLLO_TEST_IMAGE:-}" ]; then
            mercury image import "${APOLLO_TEST_IMAGE}" --alias testimage
        else
            if [ ! -e "/bin/busybox" ]; then
                echo "Please install busybox (busybox-static) or set APOLLO_TEST_IMAGE"
                exit 1
            fi

            if ldd /bin/busybox >/dev/null 2>&1; then
                echo "The testsuite requires /bin/busybox to be a static binary"
                exit 1
            fi

            deps/import-busybox --alias testimage
        fi
    fi
}
