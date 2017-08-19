# Introduction
The APOLLO client and daemon respect some environment variables to adapt to
the user's environment and to turn some advanced features on and off.

# Common
Name                            | Description
:---                            | :----
APOLLO\_DIR                        | The APOLLO data directory
PATH                            | List of paths to look into when resolving binaries
http\_proxy                     | Proxy server URL for HTTP
https\_proxy                    | Proxy server URL for HTTPs
no\_proxy                       | List of domains that don't require the use of a proxy

# Client environment variable
Name                            | Description
:---                            | :----
EDITOR                          | What text editor to use
VISUAL                          | What text editor to use (if EDITOR isn't set)

# Server environment variable
Name                            | Description
:---                            | :----
APOLLO\_SECURITY\_APPARMOR         | If set to "false", forces AppArmor off
APOLLO\_MERCURY\_TEMPLATE\_CONFIG      | Path to the MERCURY template configuration directory
