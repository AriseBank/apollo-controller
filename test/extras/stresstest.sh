#!/bin/bash
export PATH=$GOPATH/bin:$PATH

# /tmp isn't moutned exec on most systems, so we can't actually start
# containers that are created there.
export SRC_DIR=$(pwd)
export APOLLO_DIR=$(mktemp -d -p $(pwd))
chmod 777 "${APOLLO_DIR}"
export APOLLO_CONF=$(mktemp -d)
export APOLLO_FUIDMAP_DIR=${APOLLO_DIR}/fuidmap
mkdir -p ${APOLLO_FUIDMAP_DIR}
BASEURL=https://127.0.0.1:18443
RESULT=failure

set -e
if [ -n "$APOLLO_DEBUG" ]; then
    set -x
    debug=--debug
fi

echo "==> Running the APOLLO testsuite"

BASEURL=https://127.0.0.1:18443
my_curl() {
  curl -k -s --cert "${APOLLO_CONF}/client.crt" --key "${APOLLO_CONF}/client.key" $@
}

wait_for() {
  op=$($@ | jq -r .operation)
  my_curl $BASEURL$op/wait
}

mercury() {
    INJECTED=0
    CMD="$(which mercury)"
    for arg in $@; do
        if [ "$arg" = "--" ]; then
            INJECTED=1
            CMD="$CMD $debug"
            CMD="$CMD --"
        else
            CMD="$CMD \"$arg\""
        fi
    done

    if [ "$INJECTED" = "0" ]; then
        CMD="$CMD $debug"
    fi

    eval "$CMD"
}

cleanup() {
    read -p "Tests Completed ($RESULT): hit enter to continue" x
    echo "==> Cleaning up"

    # Try to stop all the containers
    my_curl "$BASEURL/1.0/containers" | jq -r .metadata[] 2>/dev/null | while read -r line; do
        wait_for my_curl -X PUT "$BASEURL$line/state" -d "{\"action\":\"stop\",\"force\":true}"
    done

    # kill the apollos which share our pgrp as parent
    mygrp=`awk '{ print $5 }' /proc/self/stat`
    for p in `pidof apollo`; do
        pgrp=`awk '{ print $5 }' /proc/$p/stat`
        if [ "$pgrp" = "$mygrp" ]; then
          do_kill_apollo $p
        fi
    done

    # Apparently we need to wait a while for everything to die
    sleep 3
    rm -Rf ${APOLLO_DIR}
    rm -Rf ${APOLLO_CONF}

    echo ""
    echo ""
    echo "==> Test result: $RESULT"
}

trap cleanup EXIT HUP INT TERM

if [ -z "`which mercury`" ]; then
    echo "==> Couldn't find mercury" && false
fi

spawn_apollo() {
  # APOLLO_DIR is local here because since `mercury` is actually a function, it
  # overwrites the environment and we would lose APOLLO_DIR's value otherwise.
  local APOLLO_DIR

  addr=$1
  apollodir=$2
  shift
  shift
  echo "==> Spawning apollo on $addr in $apollodir"
  APOLLO_DIR=$apollodir apollo ${DEBUG} $extraargs $* 2>&1 > $apollodir/apollo.log &

  echo "==> Confirming apollo on $addr is responsive"
  alive=0
  while [ $alive -eq 0 ]; do
    [ -e "${apollodir}/unix.socket" ] && APOLLO_DIR=$apollodir mercury finger && alive=1
    sleep 1s
  done

  echo "==> Binding to network"
  APOLLO_DIR=$apollodir mercury config set core.https_address $addr

  echo "==> Setting trust password"
  APOLLO_DIR=$apollodir mercury config set core.trust_password foo
}

spawn_apollo 127.0.0.1:18443 $APOLLO_DIR

## tests go here
if [ ! -e "$APOLLO_TEST_IMAGE" ]; then
    echo "Please define APOLLO_TEST_IMAGE"
    false
fi
mercury image import $APOLLO_TEST_IMAGE --alias busybox

mercury image list
mercury list

NUMCREATES=5
createthread() {
    echo "createthread: I am $$"
    for i in `seq 1 $NUMCREATES`; do
        echo "createthread: starting loop $i out of $NUMCREATES"
        declare -a pids
        for j in `seq 1 20`; do
            mercury launch busybox b.$i.$j &
            pids[$j]=$!
        done
        for j in `seq 1 20`; do
            # ignore errors if the task has already exited
            wait ${pids[$j]} 2>/dev/null || true
        done
        echo "createthread: deleting..."
        for j in `seq 1 20`; do
            mercury delete b.$i.$j &
            pids[$j]=$!
        done
        for j in `seq 1 20`; do
            # ignore errors if the task has already exited
            wait ${pids[$j]} 2>/dev/null || true
        done
    done
    exit 0
}

listthread() {
    echo "listthread: I am $$"
    while [ 1 ]; do
        mercury list
        sleep 2s
    done
    exit 0
}

configthread() {
    echo "configthread: I am $$"
    for i in `seq 1 20`; do
        mercury profile create p$i
        mercury profile set p$i limits.memory 100MB
        mercury profile delete p$i
    done
    exit 0
}

disturbthread() {
    echo "disturbthread: I am $$"
    while [ 1 ]; do
        mercury profile create empty
        mercury init busybox disturb1
        mercury profile assign disturb1 empty
        mercury start disturb1
        mercury exec disturb1 -- ps -ef
        mercury stop disturb1 --force
        mercury delete disturb1
        mercury profile delete empty
    done
    exit 0
}

echo "Starting create thread"
createthread 2>&1 | tee $APOLLO_DIR/createthread.out &
p1=$!

echo "starting the disturb thread"
disturbthread 2>&1 | tee $APOLLO_DIR/disturbthread.out &
pdisturb=$!

echo "Starting list thread"
listthread 2>&1 | tee $APOLLO_DIR/listthread.out &
p2=$!
echo "Starting config thread"
configthread 2>&1 | tee $APOLLO_DIR/configthread.out &
p3=$!

# wait for listthread to finish
wait $p1
# and configthread, it should be quick
wait $p3

echo "The creation loop is done, killing the list and disturb threads"

kill $p2
wait $p2 || true

kill $pdisturb
wait $pdisturb || true

RESULT=success
