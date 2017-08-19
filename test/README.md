# How to run

To run all tests, including the Go tests, run from repository root:

    sudo -E make check

To run only the integration tests, run from the test directory:

    sudo -E ./main.sh

# Environment variables

Name                            | Default                   | Description
:--                             | :---                      | :----------
APOLLO\_BACKEND                    | dir                       | What backend to test against (btrfs, ceph, dir, lvm, zfs, or random)
APOLLO\_CEPH\_CLUSTER              | ceph                      | The name of the ceph cluster to create osd pools in. Only used if "\${APOLLO_BACKEND}" = "ceph".
APOLLO\_CONCURRENT                 | 0                         | Run concurrency tests, very CPU intensive
APOLLO\_DEBUG                      | 0                         | Run apollo, mercury and the shell in debug mode (very verbose)
APOLLO\_INSPECT                    | 0                         | Don't teardown the test environment on failure
APOLLO\_LOGS                       | ""                        | Path to a directory to copy all the APOLLO logs to
APOLLO\_OFFLINE                    | 0                         | Skip anything that requires network access
APOLLO\_TEST\_IMAGE                | "" (busybox test image)   | Path to an image tarball to use instead of the default busybox image
APOLLO\_TMPFS                      | 0                         | Sets up a tmpfs for the whole testsuite to run on (fast but needs memory)
