#!/bin/bash

MYDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
CIMAGE="testimage"
CNAME="speedtest"

count=${1}
if [ "x${count}" == "x" ]; then
  echo "USAGE: ${0} 10"
  echo "This creates 10 busybox containers"
  exit 1
fi

if [ "x${2}" != "xnotime" ]; then
  time ${0} ${count} notime
  exit 0
fi

${MYDIR}/deps/import-busybox --alias busybox

PIDS=""
for c in $(seq 1 $count); do
  mercury init busybox "${CNAME}${c}" 2>&1 &
  PIDS="$PIDS $!"
done

for pid in $PIDS; do
  wait $pid
done

echo -e "\nmercury list: All shutdown"
time mercury list 1>/dev/null

PIDS=""
for c in $(seq 1 $count); do
  mercury start "${CNAME}${c}" 2>&1 &
  PIDS="$PIDS $!"
done

for pid in $PIDS; do
  wait $pid
done

echo -e "\nmercury list: All started"
time mercury list 1>/dev/null

echo -e "\nRun completed"
