package apollo

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"

	"github.com/gorilla/websocket"

	"github.com/AriseBank/apollo-controller/shared"
	"github.com/AriseBank/apollo-controller/shared/api"
	"github.com/AriseBank/apollo-controller/shared/logger"
)

// ProtocolAPOLLO represents a APOLLO API server
type ProtocolAPOLLO struct {
	server *api.Server

	eventListeners     []*EventListener
	eventListenersLock sync.Mutex

	http            *http.Client
	httpCertificate string
	httpHost        string
	httpProtocol    string
	httpUserAgent   string
}

// GetConnectionInfo returns the basic connection information used to interact with the server
func (r *ProtocolAPOLLO) GetConnectionInfo() (*ConnectionInfo, error) {
	info := ConnectionInfo{}
	info.Certificate = r.httpCertificate
	info.Protocol = "apollo"

	urls := []string{}
	if r.httpProtocol == "https" {
		urls = append(urls, r.httpHost)
	}

	if len(r.server.Environment.Addresses) > 0 {
		for _, addr := range r.server.Environment.Addresses {
			url := fmt.Sprintf("https://%s", addr)
			if !shared.StringInSlice(url, urls) {
				urls = append(urls, url)
			}
		}
	}
	info.Addresses = urls

	return &info, nil
}

// GetHTTPClient returns the http client used for the connection. This can be used to set custom http options.
func (r *ProtocolAPOLLO) GetHTTPClient() (*http.Client, error) {
	if r.http == nil {
		return nil, fmt.Errorf("HTTP client isn't set, bad connection")
	}

	return r.http, nil
}

// RawQuery allows directly querying the APOLLO API
//
// This should only be used by internal APOLLO tools.
func (r *ProtocolAPOLLO) RawQuery(method string, path string, data interface{}, ETag string) (*api.Response, string, error) {
	// Generate the URL
	url := fmt.Sprintf("%s%s", r.httpHost, path)

	return r.rawQuery(method, url, data, ETag)
}

// RawWebsocket allows directly connection to APOLLO API websockets
//
// This should only be used by internal APOLLO tools.
func (r *ProtocolAPOLLO) RawWebsocket(path string) (*websocket.Conn, error) {
	// Generate the URL
	url := fmt.Sprintf("%s%s", r.httpHost, path)

	return r.rawWebsocket(url)
}

// Internal functions
func (r *ProtocolAPOLLO) parseResponse(resp *http.Response) (*api.Response, string, error) {
	// Get the ETag
	etag := resp.Header.Get("ETag")

	// Decode the response
	decoder := json.NewDecoder(resp.Body)
	response := api.Response{}

	err := decoder.Decode(&response)
	if err != nil {
		// Check the return value for a cleaner error
		if resp.StatusCode != http.StatusOK {
			return nil, "", fmt.Errorf("Failed to fetch %s: %s", resp.Request.URL.String(), resp.Status)
		}

		return nil, "", err
	}

	// Handle errors
	if response.Type == api.ErrorResponse {
		return nil, "", fmt.Errorf(response.Error)
	}

	return &response, etag, nil
}

func (r *ProtocolAPOLLO) rawQuery(method string, url string, data interface{}, ETag string) (*api.Response, string, error) {
	var req *http.Request
	var err error

	// Log the request
	logger.Info("Sending request to APOLLO",
		"method", method,
		"url", url,
		"etag", ETag,
	)

	// Get a new HTTP request setup
	if data != nil {
		// Encode the provided data
		buf := bytes.Buffer{}
		err := json.NewEncoder(&buf).Encode(data)
		if err != nil {
			return nil, "", err
		}

		// Some data to be sent along with the request
		req, err = http.NewRequest(method, url, &buf)
		if err != nil {
			return nil, "", err
		}

		// Set the encoding accordingly
		req.Header.Set("Content-Type", "application/json")

		// Log the data
		logger.Debugf(logger.Pretty(data))
	} else {
		// No data to be sent along with the request
		req, err = http.NewRequest(method, url, nil)
		if err != nil {
			return nil, "", err
		}
	}

	// Set the user agent
	if r.httpUserAgent != "" {
		req.Header.Set("User-Agent", r.httpUserAgent)
	}

	// Set the ETag
	if ETag != "" {
		req.Header.Set("If-Match", ETag)
	}

	// Send the request
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()

	return r.parseResponse(resp)
}

func (r *ProtocolAPOLLO) query(method string, path string, data interface{}, ETag string) (*api.Response, string, error) {
	// Generate the URL
	url := fmt.Sprintf("%s/1.0%s", r.httpHost, path)

	return r.rawQuery(method, url, data, ETag)
}

func (r *ProtocolAPOLLO) queryStruct(method string, path string, data interface{}, ETag string, target interface{}) (string, error) {
	resp, etag, err := r.query(method, path, data, ETag)
	if err != nil {
		return "", err
	}

	err = resp.MetadataAsStruct(&target)
	if err != nil {
		return "", err
	}

	// Log the data
	logger.Debugf("Got response struct from APOLLO")
	logger.Debugf(logger.Pretty(target))

	return etag, nil
}

func (r *ProtocolAPOLLO) queryOperation(method string, path string, data interface{}, ETag string) (*Operation, string, error) {
	// Attempt to setup an early event listener
	listener, err := r.GetEvents()
	if err != nil {
		listener = nil
	}

	// Send the query
	resp, etag, err := r.query(method, path, data, ETag)
	if err != nil {
		if listener != nil {
			listener.Disconnect()
		}

		return nil, "", err
	}

	// Get to the operation
	respOperation, err := resp.MetadataAsOperation()
	if err != nil {
		if listener != nil {
			listener.Disconnect()
		}

		return nil, "", err
	}

	// Setup an Operation wrapper
	op := Operation{
		Operation: *respOperation,
		r:         r,
		listener:  listener,
		chActive:  make(chan bool),
	}

	// Log the data
	logger.Debugf("Got operation from APOLLO")
	logger.Debugf(logger.Pretty(op.Operation))

	return &op, etag, nil
}

func (r *ProtocolAPOLLO) rawWebsocket(url string) (*websocket.Conn, error) {
	// Grab the http transport handler
	httpTransport := r.http.Transport.(*http.Transport)

	// Setup a new websocket dialer based on it
	dialer := websocket.Dialer{
		NetDial:         httpTransport.Dial,
		TLSClientConfig: httpTransport.TLSClientConfig,
		Proxy:           httpTransport.Proxy,
	}

	// Set the user agent
	headers := http.Header{}
	if r.httpUserAgent != "" {
		headers.Set("User-Agent", r.httpUserAgent)
	}

	// Establish the connection
	conn, _, err := dialer.Dial(url, headers)
	if err != nil {
		return nil, err
	}

	// Log the data
	logger.Debugf("Connected to the websocket")

	return conn, err
}

func (r *ProtocolAPOLLO) websocket(path string) (*websocket.Conn, error) {
	// Generate the URL
	var url string
	if strings.HasPrefix(r.httpHost, "https://") {
		url = fmt.Sprintf("wss://%s/1.0%s", strings.TrimPrefix(r.httpHost, "https://"), path)
	} else {
		url = fmt.Sprintf("ws://%s/1.0%s", strings.TrimPrefix(r.httpHost, "http://"), path)
	}

	return r.rawWebsocket(url)
}
