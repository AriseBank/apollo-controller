Here are different ways to help troubleshooting `mercury` and `apollo` code.

#### mercury --debug

Adding `--debug` flag to any client command will give extra information
about internals. If there is no useful info, it can be added with the
logging call:

    logger.Debugf("Hello: %s", "Debug")

#### mercury monitor

This command will monitor messages as they appear on remote server.

#### apollo --debug

Shutting down `apollo` server and running it in foreground with `--debug`
flag will bring a lot of (hopefully) useful info:

    systemctl stop apollo apollo.socket
    apollo --debug --group apollo

`--group apollo` is needed to grant access to unprivileged users in this
group.


### REST API through local socket

On server side the most easy way is to communicate with APOLLO through
local socket. This command accesses `GET /1.0` and formats JSON into
human readable form using [jq](https://stedolan.github.io/jq/tutorial/)
utility:

    curl --unix-socket /var/lib/apollo/unix.socket apollo/1.0 | jq .

See [rest-api.md](rest-api.md) for available API.


### REST API through HTTPS

[HTTPS connection to APOLLO](security.md) requires valid
client certificate, generated in `~/.config/mercury/client.crt` on
first `mercury remote add`. This certificate should be passed to
connection tools for authentication and encryption.

Examining certificate. In case you are curious:

    openssl x509 -in client.crt -purpose

Among the lines you should see:

    Certificate purposes:
    SSL client : Yes

#### with command line tools

    wget --no-check-certificate https://127.0.0.1:8443/1.0 --certificate=$HOME/.config/mercury/client.crt --private-key=$HOME/.config/mercury/client.key -O - -q

#### with browser

Some browser plugins provide convenient interface to create, modify
and replay web requests. To authenticate againsg APOLLO server, convert
`mercury` client certificate into importable format and import it into
browser.

For example this produces `client.pfx` in Windows-compatible format:

    openssl pkcs12 -clcerts -inkey client.key -in client.crt -export -out client.pfx

After that, opening https://127.0.0.1:8443/1.0 should work as expected.
