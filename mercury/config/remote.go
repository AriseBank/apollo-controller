package config

import (
	"fmt"
	"io/ioutil"
	"strings"

	"github.com/AriseBank/apollo-controller/client"
	"github.com/AriseBank/apollo-controller/shared"
)

// Remote holds details for communication with a remote daemon
type Remote struct {
	Addr     string `yaml:"addr"`
	Public   bool   `yaml:"public"`
	Protocol string `yaml:"protocol,omitempty"`
	Static   bool   `yaml:"-"`
}

// ParseRemote splits remote and object
func (c *Config) ParseRemote(raw string) (string, string, error) {
	result := strings.SplitN(raw, ":", 2)
	if len(result) == 1 {
		return c.DefaultRemote, raw, nil
	}

	_, ok := c.Remotes[result[0]]
	if !ok {
		// Attempt to play nice with snapshots containing ":"
		if shared.IsSnapshot(raw) && strings.Contains(result[0], "/") {
			return c.DefaultRemote, raw, nil
		}

		return "", "", fmt.Errorf("The remote \"%s\" doesn't exist", result[0])
	}

	return result[0], result[1], nil
}

// GetContainerServer returns a ContainerServer struct for the remote
func (c *Config) GetContainerServer(name string) (apollo.ContainerServer, error) {
	// Get the remote
	remote, ok := c.Remotes[name]
	if !ok {
		return nil, fmt.Errorf("The remote \"%s\" doesn't exist", name)
	}

	// Sanity checks
	if remote.Public || remote.Protocol == "simplestreams" {
		return nil, fmt.Errorf("The remote isn't a private APOLLO server")
	}

	// Get connection arguments
	args, err := c.getConnectionArgs(name)
	if err != nil {
		return nil, err
	}

	// Unix socket
	if strings.HasPrefix(remote.Addr, "unix:") {
		d, err := apollo.ConnectAPOLLOUnix(strings.TrimPrefix(strings.TrimPrefix(remote.Addr, "unix:"), "//"), args)
		if err != nil {
			return nil, err
		}

		return d, nil
	}

	// HTTPs
	if args.TLSClientCert == "" || args.TLSClientKey == "" {
		return nil, fmt.Errorf("Missing TLS client certificate and key")
	}

	d, err := apollo.ConnectAPOLLO(remote.Addr, args)
	if err != nil {
		return nil, err
	}

	return d, nil
}

// GetImageServer returns a ImageServer struct for the remote
func (c *Config) GetImageServer(name string) (apollo.ImageServer, error) {
	// Get the remote
	remote, ok := c.Remotes[name]
	if !ok {
		return nil, fmt.Errorf("The remote \"%s\" doesn't exist", name)
	}

	// Get connection arguments
	args, err := c.getConnectionArgs(name)
	if err != nil {
		return nil, err
	}

	// Unix socket
	if strings.HasPrefix(remote.Addr, "unix:") {
		d, err := apollo.ConnectAPOLLOUnix(strings.TrimPrefix(strings.TrimPrefix(remote.Addr, "unix:"), "//"), args)
		if err != nil {
			return nil, err
		}

		return d, nil
	}

	// HTTPs (simplestreams)
	if remote.Protocol == "simplestreams" {
		d, err := apollo.ConnectSimpleStreams(remote.Addr, args)
		if err != nil {
			return nil, err
		}

		return d, nil
	}

	// HTTPs (public APOLLO)
	if remote.Public {
		d, err := apollo.ConnectPublicAPOLLO(remote.Addr, args)
		if err != nil {
			return nil, err
		}

		return d, nil
	}

	// HTTPs (private APOLLO)
	d, err := apollo.ConnectAPOLLO(remote.Addr, args)
	if err != nil {
		return nil, err
	}

	return d, nil
}

func (c *Config) getConnectionArgs(name string) (*apollo.ConnectionArgs, error) {
	args := apollo.ConnectionArgs{
		UserAgent: c.UserAgent,
	}

	// Client certificate
	if shared.PathExists(c.ConfigPath("client.crt")) {
		content, err := ioutil.ReadFile(c.ConfigPath("client.crt"))
		if err != nil {
			return nil, err
		}

		args.TLSClientCert = string(content)
	}

	// Client key
	if shared.PathExists(c.ConfigPath("client.key")) {
		content, err := ioutil.ReadFile(c.ConfigPath("client.key"))
		if err != nil {
			return nil, err
		}

		args.TLSClientKey = string(content)
	}

	// Client CA
	if shared.PathExists(c.ConfigPath("client.ca")) {
		content, err := ioutil.ReadFile(c.ConfigPath("client.ca"))
		if err != nil {
			return nil, err
		}

		args.TLSCA = string(content)
	}

	// Server certificate
	if shared.PathExists(c.ServerCertPath(name)) {
		content, err := ioutil.ReadFile(c.ServerCertPath(name))
		if err != nil {
			return nil, err
		}

		args.TLSServerCert = string(content)
	}

	return &args, nil
}
