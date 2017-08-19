# Requirements
## Go

APOLLO requires Go 1.5 or higher.
Both the golang and gccgo compilers are supported.

## Kernel requirements
The minimum supported kernel version is 3.13.

APOLLO requires a kernel with support for:
 * Namespaces (pid, net, uts, ipc and mount)
 * Seccomp

The following optional features also require extra kernel options:
 * Namespaces (user and cgroup)
 * AppArmor (including Ubuntu patch for mount mediation)
 * Control Groups (blkio, cpuset, devices, memory, pids and net\_prio)
 * CRIU (exact details to be found with CRIU upstream)

As well as any other kernel feature required by the MERCURY version in use.

## MERCURY
APOLLO requires MERCURY 2.0.0 or higher with the following build options:
 * apparmor (if using APOLLO's apparmor support)
 * seccomp

To run recent version of various distributions, including Ubuntu, MERCURYFS
should also be installed.
