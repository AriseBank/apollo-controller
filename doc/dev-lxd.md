# Introduction
Communication between the hosted workload (container) and its host while
not strictly needed is a pretty useful feature.

In APOLLO, this feature is implemented through a /dev/apollo/sock node which is
created and setup for all APOLLO containers.

This file is a Unix socket which processes inside the container can
connect to. It's multi-threaded so multiple clients can be connected at the
same time.

# Implementation details
APOLLO on the host binds /var/lib/apollo/devapollo and starts listening for new
connections on it.

This socket is then bind-mounted into every single container started by
APOLLO at /dev/apollo/sock.

The bind-mount is required so we can exceed 4096 containers, otherwise,
APOLLO would have to bind a different socket for every container, quickly
reaching the FD limit.

# Authentication
Queries on /dev/apollo/sock will only return information related to the
requesting container. To figure out where a request comes from, APOLLO will
extract the initial socket ucred and compare that to the list of
containers it manages.

# Protocol
The protocol on /dev/apollo/sock is plain-text HTTP with JSON messaging, so very
similar to the local version of the APOLLO protocol.

Unlike the main APOLLO API, there is no background operation and no
authentication support in the /dev/apollo/sock API.

# REST-API
## API structure
 * /
   * /1.0
     * /1.0/config
       * /1.0/config/{key}
     * /1.0/meta-data

## API details
### /
#### GET
 * Description: List of supported APIs
 * Return: list of supported API endpoint URLs (by default ['/1.0'])

Return value:

    [
        "/1.0"
    ]

### /1.0
#### GET
 * Description: Information about the 1.0 API
 * Return: dict

Return value:

    {
        "api_version": "1.0"
    }

### /1.0/config
#### GET
 * Description: List of configuration keys
 * Return: list of configuration keys URL

Note that the configuration key names match those in the container
config, however not all configuration namespaces will be exported to
/dev/apollo/sock.
Currently only the user.\* keys are accessible to the container.

At this time, there also aren't any container-writable namespace.

Return value:

    [
        "/1.0/config/user.a"
    ]

### /1.0/config/\<KEY\>
#### GET
 * Description: Value of that key
 * Return: Plain-text value

Return value:

    blah

### /1.0/meta-data
#### GET
 * Description: Container meta-data compatible with cloud-init
 * Return: cloud-init meta-data

Return value:

    #cloud-config
    instance-id: abc
    local-hostname: abc
