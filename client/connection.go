package apollo

import (
	"net/http"
	"net/url"
	"os"
	"path/filepath"

	"github.com/AriseBank/apollo-controller/shared/logger"
	"github.com/AriseBank/apollo-controller/shared/simplestreams"
)

// ConnectionArgs represents a set of common connection properties
type ConnectionArgs struct {
	// TLS certificate of the remote server. If not specified, the system CA is used.
	TLSServerCert string

	// TLS certificate to use for client authentication.
	TLSClientCert string

	// TLS key to use for client authentication.
	TLSClientKey string

	// TLS CA to validate against when in PKI mode.
	TLSCA string

	// User agent string
	UserAgent string

	// Custom proxy
	Proxy func(*http.Request) (*url.URL, error)

	// Custom HTTP Client (used as base for the connection)
	HTTPClient *http.Client
}

// ConnectAPOLLO lets you connect to a remote APOLLO daemon over HTTPs.
//
// A client certificate (TLSClientCert) and key (TLSClientKey) must be provided.
//
// If connecting to a APOLLO daemon running in PKI mode, the PKI CA (TLSCA) must also be provided.
//
// Unless the remote server is trusted by the system CA, the remote certificate must be provided (TLSServerCert).
func ConnectAPOLLO(url string, args *ConnectionArgs) (ContainerServer, error) {
	logger.Infof("Connecting to a remote APOLLO over HTTPs")

	return httpsAPOLLO(url, args)
}

// ConnectAPOLLOUnix lets you connect to a remote APOLLO daemon over a local unix socket.
//
// If the path argument is empty, then $APOLLO_DIR/unix.socket will be used.
// If that one isn't set either, then the path will default to /var/lib/apollo/unix.socket.
func ConnectAPOLLOUnix(path string, args *ConnectionArgs) (ContainerServer, error) {
	logger.Infof("Connecting to a local APOLLO over a Unix socket")

	// Use empty args if not specified
	if args == nil {
		args = &ConnectionArgs{}
	}

	// Initialize the client struct
	server := ProtocolAPOLLO{
		httpHost:      "http://unix.socket",
		httpProtocol:  "unix",
		httpUserAgent: args.UserAgent,
	}

	// Determine the socket path
	if path == "" {
		apolloDir := os.Getenv("APOLLO_DIR")
		if apolloDir == "" {
			apolloDir = "/var/lib/apollo"
		}

		path = filepath.Join(apolloDir, "unix.socket")
	}

	// Setup the HTTP client
	httpClient, err := unixHTTPClient(args.HTTPClient, path)
	if err != nil {
		return nil, err
	}
	server.http = httpClient

	// Test the connection and seed the server information
	serverStatus, _, err := server.GetServer()
	if err != nil {
		return nil, err
	}

	// Record the server certificate
	server.httpCertificate = serverStatus.Environment.Certificate

	return &server, nil
}

// ConnectPublicAPOLLO lets you connect to a remote public APOLLO daemon over HTTPs.
//
// Unless the remote server is trusted by the system CA, the remote certificate must be provided (TLSServerCert).
func ConnectPublicAPOLLO(url string, args *ConnectionArgs) (ImageServer, error) {
	logger.Infof("Connecting to a remote public APOLLO over HTTPs")

	return httpsAPOLLO(url, args)
}

// ConnectSimpleStreams lets you connect to a remote SimpleStreams image server over HTTPs.
//
// Unless the remote server is trusted by the system CA, the remote certificate must be provided (TLSServerCert).
func ConnectSimpleStreams(url string, args *ConnectionArgs) (ImageServer, error) {
	logger.Infof("Connecting to a remote simplestreams server")

	// Use empty args if not specified
	if args == nil {
		args = &ConnectionArgs{}
	}

	// Initialize the client struct
	server := ProtocolSimpleStreams{
		httpHost:        url,
		httpUserAgent:   args.UserAgent,
		httpCertificate: args.TLSServerCert,
	}

	// Setup the HTTP client
	httpClient, err := tlsHTTPClient(args.HTTPClient, args.TLSClientCert, args.TLSClientKey, args.TLSCA, args.TLSServerCert, args.Proxy)
	if err != nil {
		return nil, err
	}
	server.http = httpClient

	// Get simplestreams client
	ssClient := simplestreams.NewClient(url, *httpClient, args.UserAgent)
	server.ssClient = ssClient

	return &server, nil
}

// Internal function called by ConnectAPOLLO and ConnectPublicAPOLLO
func httpsAPOLLO(url string, args *ConnectionArgs) (ContainerServer, error) {
	// Use empty args if not specified
	if args == nil {
		args = &ConnectionArgs{}
	}

	// Initialize the client struct
	server := ProtocolAPOLLO{
		httpCertificate: args.TLSServerCert,
		httpHost:        url,
		httpProtocol:    "https",
		httpUserAgent:   args.UserAgent,
	}

	// Setup the HTTP client
	httpClient, err := tlsHTTPClient(args.HTTPClient, args.TLSClientCert, args.TLSClientKey, args.TLSCA, args.TLSServerCert, args.Proxy)
	if err != nil {
		return nil, err
	}
	server.http = httpClient

	// Test the connection and seed the server information
	_, _, err = server.GetServer()
	if err != nil {
		return nil, err
	}

	return &server, nil
}
