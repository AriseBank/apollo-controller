test_container_import() {
  ensure_import_testimage

  APOLLO_IMPORT_DIR=$(mktemp -d -p "${TEST_DIR}" XXX)
  chmod +x "${APOLLO_IMPORT_DIR}"
  spawn_apollo "${APOLLO_IMPORT_DIR}" true
  (
    mercury init testimage ctImport
    mercury start ctImport
    pid=$(mercury info ctImport | grep ^Pid | awk '{print $2}')
    ! apollo import ctImport
    apollo import ctImport --force
    kill -9 "${pid}"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM storage_volumes WHERE name='ctImport'"
    apollo import ctImport --force
    mercury delete --force ctImport

    mercury init testimage ctImport
    mercury snapshot ctImport
    mercury start ctImport
    pid=$(mercury info ctImport | grep ^Pid | awk '{print $2}')
    ! apollo import ctImport
    apollo import ctImport --force
    kill -9 "${pid}"
    mercury info ctImport | grep snap0
    mercury start ctImport
    mercury delete --force ctImport

    mercury init testimage ctImport
    mercury snapshot ctImport
    mercury start ctImport
    pid=$(mercury info ctImport | grep ^Pid | awk '{print $2}')
    shutdown_apollo "${APOLLO_IMPORT_DIR}"
    kill -9 "${pid}"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport'"
    respawn_apollo "${APOLLO_IMPORT_DIR}"
    ! apollo import ctImport
    apollo import ctImport --force
    mercury info ctImport | grep snap0
    mercury delete --force ctImport

    mercury init testimage ctImport
    mercury snapshot ctImport
    mercury start ctImport
    pid=$(mercury info ctImport | grep ^Pid | awk '{print $2}')
    shutdown_apollo "${APOLLO_IMPORT_DIR}"
    kill -9 "${pid}"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport/snap0'"
    respawn_apollo "${APOLLO_IMPORT_DIR}"
    ! apollo import ctImport
    apollo import ctImport --force
    mercury info ctImport | grep snap0
    mercury delete --force ctImport

    mercury init testimage ctImport
    mercury snapshot ctImport
    mercury start ctImport
    pid=$(mercury info ctImport | grep ^Pid | awk '{print $2}')
    shutdown_apollo "${APOLLO_IMPORT_DIR}"
    kill -9 "${pid}"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport/snap0'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM storage_volumes WHERE name='ctImport'"
    respawn_apollo "${APOLLO_IMPORT_DIR}"
    ! apollo import ctImport
    apollo import ctImport --force
    mercury info ctImport | grep snap0
    mercury delete --force ctImport

    mercury init testimage ctImport
    mercury snapshot ctImport
    mercury start ctImport
    pid=$(mercury info ctImport | grep ^Pid | awk '{print $2}')
    shutdown_apollo "${APOLLO_IMPORT_DIR}"
    kill -9 "${pid}"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport/snap0'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM storage_volumes WHERE name='ctImport'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM storage_volumes WHERE name='ctImport/snap0'"
    respawn_apollo "${APOLLO_IMPORT_DIR}"
    apollo import ctImport
    apollo import ctImport --force
    mercury info ctImport | grep snap0
    mercury delete --force ctImport

    mercury init testimage ctImport
    mercury snapshot ctImport
    mercury start ctImport
    rm "${APOLLO_DIR}/containers/ctImport"
    pid=$(mercury info ctImport | grep ^Pid | awk '{print $2}')
    shutdown_apollo "${APOLLO_IMPORT_DIR}"
    kill -9 "${pid}"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM containers WHERE name='ctImport/snap0'"
    sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM storage_volumes WHERE name='ctImport'"
    respawn_apollo "${APOLLO_IMPORT_DIR}"
    ! apollo import ctImport
    apollo import ctImport --force
    mercury info ctImport | grep snap0
    mercury delete --force ctImport

    # Test whether a snapshot that exists on disk but not in the "backup.yaml"
    # file is correctly restored. This can be done by not starting the parent
    # container which avoids that the backup file is written out.
    if [ "$(storage_backend "$APOLLO_DIR")" = "dir" ]; then
      mercury init testimage ctImport
      mercury snapshot ctImport
      shutdown_apollo "${APOLLO_IMPORT_DIR}"
      sqlite3 "${APOLLO_DIR}/apollo.db" "PRAGMA foreign_keys=ON; DELETE FROM storage_volumes WHERE name='ctImport/snap0'"
      respawn_apollo "${APOLLO_IMPORT_DIR}"
      ! apollo import ctImport
      apollo import ctImport --force
      mercury info ctImport | grep snap0
      mercury delete --force ctImport
    fi
  )
  # shellcheck disable=SC2031
  kill_apollo "${APOLLO_IMPORT_DIR}"
}
