test_idmap() {
  # Check that we have a big enough range for this test
  if [ ! -e /etc/subuid ] && [ ! -e /etc/subgid ]; then
    UIDs=1000000000
    GIDs=1000000000
    UID_BASE=1000000
    GID_BASE=1000000
  else
    UIDs=0
    GIDs=0
    UID_BASE=0
    GID_BASE=0
    LARGEST_UIDs=0
    LARGEST_GIDs=0

    # shellcheck disable=SC2013
    for entry in $(grep ^root: /etc/subuid); do
      COUNT=$(echo "${entry}" | cut -d: -f3)
      UIDs=$((UIDs+COUNT))

      if [ "${COUNT}" -gt "${LARGEST_UIDs}" ]; then
        LARGEST_UIDs=${COUNT}
        UID_BASE=$(echo "${entry}" | cut -d: -f2)
      fi
    done

    # shellcheck disable=SC2013
    for entry in $(grep ^root: /etc/subgid); do
      COUNT=$(echo "${entry}" | cut -d: -f3)
      GIDs=$((GIDs+COUNT))

      if [ "${COUNT}" -gt "${LARGEST_GIDs}" ]; then
        LARGEST_GIDs=${COUNT}
        GID_BASE=$(echo "${entry}" | cut -d: -f2)
      fi
    done
  fi

  if [ "${UIDs}" -lt 500000 ] || [ "${GIDs}" -lt 500000 ]; then
    echo "==> SKIP: The idmap test requires at least 500000 uids and gids"
    return
  fi

  # Setup daemon
  ensure_import_testimage

  # Check a normal, non-isolated container (full APOLLO id range)
  mercury launch testimage idmap
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')" = "${UID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')" = "${GID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $3}')" = "${UIDs}" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $3}')" = "${GIDs}" ]

  # Convert container to isolated and confirm it's not using the first range
  mercury config set idmap security.idmap.isolated true
  mercury restart idmap --force
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')" = "$((UID_BASE+65536))" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')" = "$((GID_BASE+65536))" ]
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $3}')" = "65536" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $3}')" = "65536" ]

  # Bump allocation size
  mercury config set idmap security.idmap.size 100000
  mercury restart idmap --force
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')" != "${UID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')" != "${GID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $3}')" = "100000" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $3}')" = "100000" ]

  # Test using a custom base
  mercury config set idmap security.idmap.base $((UID_BASE+12345))
  mercury config set idmap security.idmap.size 110000
  mercury restart idmap --force
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')" = "$((UID_BASE+12345))" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')" = "$((GID_BASE+12345))" ]
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $3}')" = "110000" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $3}')" = "110000" ]

  # Switch back to full APOLLO range
  mercury config unset idmap security.idmap.base
  mercury config unset idmap security.idmap.isolated
  mercury config unset idmap security.idmap.size
  mercury restart idmap --force
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')" = "${UID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')" = "${GID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $3}')" = "${UIDs}" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $3}')" = "${GIDs}" ]
  mercury delete idmap --force

  # Confirm id recycling
  mercury launch testimage idmap -c security.idmap.isolated=true
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')" = "$((UID_BASE+65536))" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')" = "$((GID_BASE+65536))" ]
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $3}')" = "65536" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $3}')" = "65536" ]

  # Copy and check that the base differs
  mercury copy idmap idmap1
  mercury start idmap1
  [ "$(mercury exec idmap1 -- cat /proc/self/uid_map | awk '{print $2}')" = "$((UID_BASE+131072))" ]
  [ "$(mercury exec idmap1 -- cat /proc/self/gid_map | awk '{print $2}')" = "$((GID_BASE+131072))" ]
  [ "$(mercury exec idmap1 -- cat /proc/self/uid_map | awk '{print $3}')" = "65536" ]
  [ "$(mercury exec idmap1 -- cat /proc/self/gid_map | awk '{print $3}')" = "65536" ]

  # Validate non-overlapping maps
  mercury exec idmap -- touch /a
  ! mercury exec idmap -- chown 65536 /a
  mercury exec idmap -- chown 65535 /a
  PID_1=$(mercury info idmap | grep ^Pid | awk '{print $2}')
  UID_1=$(stat -c '%u' "/proc/${PID_1}/root/a")

  mercury exec idmap1 -- touch /a
  PID_2=$(mercury info idmap1 | grep ^Pid | awk '{print $2}')
  UID_2=$(stat -c '%u' "/proc/${PID_2}/root/a")

  [ "${UID_1}" != "${UID_2}" ]
  [ "${UID_2}" = "$((UID_1+1))" ]

  # Check profile inheritance
  mercury profile create idmap
  mercury profile set idmap security.idmap.isolated true
  mercury profile set idmap security.idmap.size 100000

  mercury launch testimage idmap2
  [ "$(mercury exec idmap2 -- cat /proc/self/uid_map | awk '{print $2}')" = "${UID_BASE}" ]
  [ "$(mercury exec idmap2 -- cat /proc/self/gid_map | awk '{print $2}')" = "${GID_BASE}" ]
  [ "$(mercury exec idmap2 -- cat /proc/self/uid_map | awk '{print $3}')" = "${UIDs}" ]
  [ "$(mercury exec idmap2 -- cat /proc/self/gid_map | awk '{print $3}')" = "${GIDs}" ]

  mercury profile add idmap idmap
  mercury profile add idmap1 idmap
  mercury profile add idmap2 idmap
  mercury restart idmap idmap1 idmap2 --force
  mercury launch testimage idmap3 -p default -p idmap

  UID_1=$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')
  GID_1=$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $2}')" != "${UID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $2}')" != "${GID_BASE}" ]
  [ "$(mercury exec idmap -- cat /proc/self/uid_map | awk '{print $3}')" = "100000" ]
  [ "$(mercury exec idmap -- cat /proc/self/gid_map | awk '{print $3}')" = "100000" ]

  UID_2=$(mercury exec idmap1 -- cat /proc/self/uid_map | awk '{print $2}')
  GID_2=$(mercury exec idmap1 -- cat /proc/self/gid_map | awk '{print $2}')
  [ "$(mercury exec idmap1 -- cat /proc/self/uid_map | awk '{print $2}')" != "${UID_BASE}" ]
  [ "$(mercury exec idmap1 -- cat /proc/self/gid_map | awk '{print $2}')" != "${GID_BASE}" ]
  [ "$(mercury exec idmap1 -- cat /proc/self/uid_map | awk '{print $3}')" = "100000" ]
  [ "$(mercury exec idmap1 -- cat /proc/self/gid_map | awk '{print $3}')" = "100000" ]

  UID_3=$(mercury exec idmap2 -- cat /proc/self/uid_map | awk '{print $2}')
  GID_3=$(mercury exec idmap2 -- cat /proc/self/gid_map | awk '{print $2}')
  [ "$(mercury exec idmap2 -- cat /proc/self/uid_map | awk '{print $2}')" != "${UID_BASE}" ]
  [ "$(mercury exec idmap2 -- cat /proc/self/gid_map | awk '{print $2}')" != "${GID_BASE}" ]
  [ "$(mercury exec idmap2 -- cat /proc/self/uid_map | awk '{print $3}')" = "100000" ]
  [ "$(mercury exec idmap2 -- cat /proc/self/gid_map | awk '{print $3}')" = "100000" ]

  UID_4=$(mercury exec idmap3 -- cat /proc/self/uid_map | awk '{print $2}')
  GID_4=$(mercury exec idmap3 -- cat /proc/self/gid_map | awk '{print $2}')
  [ "$(mercury exec idmap3 -- cat /proc/self/uid_map | awk '{print $2}')" != "${UID_BASE}" ]
  [ "$(mercury exec idmap3 -- cat /proc/self/gid_map | awk '{print $2}')" != "${GID_BASE}" ]
  [ "$(mercury exec idmap3 -- cat /proc/self/uid_map | awk '{print $3}')" = "100000" ]
  [ "$(mercury exec idmap3 -- cat /proc/self/gid_map | awk '{print $3}')" = "100000" ]

  [ "${UID_1}" != "${UID_2}" ]
  [ "${UID_1}" != "${UID_3}" ]
  [ "${UID_1}" != "${UID_4}" ]
  [ "${UID_2}" != "${UID_3}" ]
  [ "${UID_2}" != "${UID_4}" ]
  [ "${UID_3}" != "${UID_4}" ]

  [ "${GID_1}" != "${GID_2}" ]
  [ "${GID_1}" != "${GID_3}" ]
  [ "${GID_1}" != "${GID_4}" ]
  [ "${GID_2}" != "${GID_3}" ]
  [ "${GID_2}" != "${GID_4}" ]
  [ "${UID_3}" != "${UID_4}" ]

  mercury delete idmap1 idmap2 idmap3 --force

  # Test running out of ids
  ! mercury launch testimage idmap1 -c security.idmap.isolated=true -c security.idmap.size=$((UIDs+1))

  # Test raw id maps
  (
  cat << EOF
uid ${UID_BASE} 1000000
gid $((GID_BASE+1)) 1000000
both $((UID_BASE+2)) 2000000
EOF
  ) | mercury config set idmap raw.idmap -
  mercury restart idmap --force
  PID=$(mercury info idmap | grep ^Pid | awk '{print $2}')

  mercury exec idmap -- touch /a
  mercury exec idmap -- chown 1000000:1000000 /a
  [ "$(stat -c '%u:%g' "/proc/${PID}/root/a")" = "${UID_BASE}:$((GID_BASE+1))" ]

  mercury exec idmap -- touch /b
  mercury exec idmap -- chown 2000000:2000000 /b
  [ "$(stat -c '%u:%g' "/proc/${PID}/root/b")" = "$((UID_BASE+2)):$((GID_BASE+2))" ]

  # Test id ranges
  (
  cat << EOF
uid $((UID_BASE+10))-$((UID_BASE+19)) 3000000-3000009
gid $((GID_BASE+10))-$((GID_BASE+19)) 3000000-3000009
both $((GID_BASE+20))-$((GID_BASE+29)) 4000000-4000009
EOF
  ) | mercury config set idmap raw.idmap -
  mercury restart idmap --force
  PID=$(mercury info idmap | grep ^Pid | awk '{print $2}')

  mercury exec idmap -- touch /c
  mercury exec idmap -- chown 3000009:3000009 /c
  [ "$(stat -c '%u:%g' "/proc/${PID}/root/c")" = "$((UID_BASE+19)):$((GID_BASE+19))" ]

  mercury exec idmap -- touch /d
  mercury exec idmap -- chown 4000009:4000009 /d
  [ "$(stat -c '%u:%g' "/proc/${PID}/root/d")" = "$((UID_BASE+29)):$((GID_BASE+29))" ]

  mercury delete idmap --force
}
