package apollo

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/gorilla/websocket"

	"github.com/AriseBank/apollo-controller/shared"
	"github.com/AriseBank/apollo-controller/shared/api"
)

// Container handling functions

// GetContainerNames returns a list of container names
func (r *ProtocolAPOLLO) GetContainerNames() ([]string, error) {
	urls := []string{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", "/containers", nil, "", &urls)
	if err != nil {
		return nil, err
	}

	// Parse it
	names := []string{}
	for _, url := range urls {
		fields := strings.Split(url, "/containers/")
		names = append(names, fields[len(fields)-1])
	}

	return names, nil
}

// GetContainers returns a list of containers
func (r *ProtocolAPOLLO) GetContainers() ([]api.Container, error) {
	containers := []api.Container{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", "/containers?recursion=1", nil, "", &containers)
	if err != nil {
		return nil, err
	}

	return containers, nil
}

// GetContainer returns the container entry for the provided name
func (r *ProtocolAPOLLO) GetContainer(name string) (*api.Container, string, error) {
	container := api.Container{}

	// Fetch the raw value
	etag, err := r.queryStruct("GET", fmt.Sprintf("/containers/%s", name), nil, "", &container)
	if err != nil {
		return nil, "", err
	}

	return &container, etag, nil
}

// CreateContainer requests that APOLLO creates a new container
func (r *ProtocolAPOLLO) CreateContainer(container api.ContainersPost) (*Operation, error) {
	if container.Source.ContainerOnly {
		if !r.HasExtension("container_only_migration") {
			return nil, fmt.Errorf("The server is missing the required \"container_only_migration\" API extension")
		}
	}

	// Send the request
	op, _, err := r.queryOperation("POST", "/containers", container, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

func (r *ProtocolAPOLLO) tryCreateContainer(req api.ContainersPost, urls []string) (*RemoteOperation, error) {
	if len(urls) == 0 {
		return nil, fmt.Errorf("The source server isn't listening on the network")
	}

	rop := RemoteOperation{
		chDone: make(chan bool),
	}

	operation := req.Source.Operation

	// Forward targetOp to remote op
	go func() {
		success := false
		errors := []string{}
		for _, serverURL := range urls {
			if operation == "" {
				req.Source.Server = serverURL
			} else {
				req.Source.Operation = fmt.Sprintf("%s/1.0/operations/%s", serverURL, operation)
			}

			op, err := r.CreateContainer(req)
			if err != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", serverURL, err))
				continue
			}

			rop.targetOp = op

			for _, handler := range rop.handlers {
				rop.targetOp.AddHandler(handler)
			}

			err = rop.targetOp.Wait()
			if err != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", serverURL, err))
				continue
			}

			success = true
			break
		}

		if !success {
			rop.err = fmt.Errorf("Failed container creation:\n - %s", strings.Join(errors, "\n - "))
		}

		close(rop.chDone)
	}()

	return &rop, nil
}

// CreateContainerFromImage is a convenience function to make it easier to create a container from an existing image
func (r *ProtocolAPOLLO) CreateContainerFromImage(source ImageServer, image api.Image, req api.ContainersPost) (*RemoteOperation, error) {
	// Set the minimal source fields
	req.Source.Type = "image"

	// Optimization for the local image case
	if r == source {
		// Always use fingerprints for local case
		req.Source.Fingerprint = image.Fingerprint
		req.Source.Alias = ""

		op, err := r.CreateContainer(req)
		if err != nil {
			return nil, err
		}

		rop := RemoteOperation{
			targetOp: op,
			chDone:   make(chan bool),
		}

		// Forward targetOp to remote op
		go func() {
			rop.err = rop.targetOp.Wait()
			close(rop.chDone)
		}()

		return &rop, nil
	}

	// Minimal source fields for remote image
	req.Source.Mode = "pull"

	// If we have an alias and the image is public, use that
	if req.Source.Alias != "" && image.Public {
		req.Source.Fingerprint = ""
	} else {
		req.Source.Fingerprint = image.Fingerprint
		req.Source.Alias = ""
	}

	// Get source server connection information
	info, err := source.GetConnectionInfo()
	if err != nil {
		return nil, err
	}

	req.Source.Protocol = info.Protocol
	req.Source.Certificate = info.Certificate

	// Generate secret token if needed
	if !image.Public {
		secret, err := source.GetImageSecret(image.Fingerprint)
		if err != nil {
			return nil, err
		}

		req.Source.Secret = secret
	}

	return r.tryCreateContainer(req, info.Addresses)
}

// CopyContainer copies a container from a remote server. Additional options can be passed using ContainerCopyArgs
func (r *ProtocolAPOLLO) CopyContainer(source ContainerServer, container api.Container, args *ContainerCopyArgs) (*RemoteOperation, error) {
	// Base request
	req := api.ContainersPost{
		Name:         container.Name,
		ContainerPut: container.Writable(),
	}
	req.Source.BaseImage = container.Config["volatile.base_image"]

	// Process the copy arguments
	if args != nil {
		// Sanity checks
		if args.ContainerOnly {
			if !r.HasExtension("container_only_migration") {
				return nil, fmt.Errorf("The target server is missing the required \"container_only_migration\" API extension")
			}

			if !source.HasExtension("container_only_migration") {
				return nil, fmt.Errorf("The source server is missing the required \"container_only_migration\" API extension")
			}
		}

		if shared.StringInSlice(args.Mode, []string{"push", "relay"}) {
			if !r.HasExtension("container_push") {
				return nil, fmt.Errorf("The target server is missing the required \"container_push\" API extension")
			}

			if !source.HasExtension("container_push") {
				return nil, fmt.Errorf("The source server is missing the required \"container_push\" API extension")
			}
		}

		if args.Mode == "push" && !source.HasExtension("container_push_target") {
			return nil, fmt.Errorf("The source server is missing the required \"container_push_target\" API extension")
		}

		// Allow overriding the target name
		if args.Name != "" {
			req.Name = args.Name
		}

		req.Source.Live = args.Live
		req.Source.ContainerOnly = args.ContainerOnly
	}

	if req.Source.Live {
		req.Source.Live = container.StatusCode == api.Running
	}

	// Optimization for the local copy case
	if r == source {
		// Local copy source fields
		req.Source.Type = "copy"
		req.Source.Source = container.Name

		// Copy the container
		op, err := r.CreateContainer(req)
		if err != nil {
			return nil, err
		}

		rop := RemoteOperation{
			targetOp: op,
			chDone:   make(chan bool),
		}

		// Forward targetOp to remote op
		go func() {
			rop.err = rop.targetOp.Wait()
			close(rop.chDone)
		}()

		return &rop, nil
	}

	// Source request
	sourceReq := api.ContainerPost{
		Migration:     true,
		Live:          req.Source.Live,
		ContainerOnly: req.Source.ContainerOnly,
	}

	// Push mode migration
	if args != nil && args.Mode == "push" {
		// Get target server connection information
		info, err := r.GetConnectionInfo()
		if err != nil {
			return nil, err
		}

		// Create the container
		req.Source.Type = "migration"
		req.Source.Mode = "push"

		op, err := r.CreateContainer(req)
		if err != nil {
			return nil, err
		}

		targetSecrets := map[string]string{}
		for k, v := range op.Metadata {
			targetSecrets[k] = v.(string)
		}

		// Prepare the source request
		target := api.ContainerPostTarget{}
		target.Operation = op.ID
		target.Websockets = targetSecrets
		target.Certificate = info.Certificate
		sourceReq.Target = &target

		return r.tryMigrateContainer(source, container.Name, sourceReq, info.Addresses)
	}

	// Get source server connection information
	info, err := source.GetConnectionInfo()
	if err != nil {
		return nil, err
	}

	op, err := source.MigrateContainer(container.Name, sourceReq)
	if err != nil {
		return nil, err
	}

	sourceSecrets := map[string]string{}
	for k, v := range op.Metadata {
		sourceSecrets[k] = v.(string)
	}

	// Relay mode migration
	if args != nil && args.Mode == "relay" {
		// Push copy source fields
		req.Source.Type = "migration"
		req.Source.Mode = "push"

		// Start the process
		targetOp, err := r.CreateContainer(req)
		if err != nil {
			return nil, err
		}

		// Extract the websockets
		targetSecrets := map[string]string{}
		for k, v := range targetOp.Metadata {
			targetSecrets[k] = v.(string)
		}

		// Launch the relay
		err = r.proxyMigration(targetOp, targetSecrets, source, op, sourceSecrets)
		if err != nil {
			return nil, err
		}

		// Prepare a tracking operation
		rop := RemoteOperation{
			targetOp: targetOp,
			chDone:   make(chan bool),
		}

		// Forward targetOp to remote op
		go func() {
			rop.err = rop.targetOp.Wait()
			close(rop.chDone)
		}()

		return &rop, nil
	}

	// Pull mode migration
	req.Source.Type = "migration"
	req.Source.Mode = "pull"
	req.Source.Operation = op.ID
	req.Source.Websockets = sourceSecrets
	req.Source.Certificate = info.Certificate

	return r.tryCreateContainer(req, info.Addresses)
}

func (r *ProtocolAPOLLO) proxyMigration(targetOp *Operation, targetSecrets map[string]string, source ContainerServer, sourceOp *Operation, sourceSecrets map[string]string) error {
	// Sanity checks
	for n := range targetSecrets {
		_, ok := sourceSecrets[n]
		if !ok {
			return fmt.Errorf("Migration target expects the \"%s\" socket but source isn't providing it", n)
		}
	}

	if targetSecrets["control"] == "" {
		return fmt.Errorf("Migration target didn't setup the required \"control\" socket")
	}

	// Struct used to hold everything together
	type proxy struct {
		done       chan bool
		sourceConn *websocket.Conn
		targetConn *websocket.Conn
	}

	proxies := map[string]*proxy{}

	// Connect the control socket
	sourceConn, err := source.GetOperationWebsocket(sourceOp.ID, sourceSecrets["control"])
	if err != nil {
		return err
	}

	targetConn, err := r.GetOperationWebsocket(targetOp.ID, targetSecrets["control"])
	if err != nil {
		return err
	}

	proxies["control"] = &proxy{
		done:       shared.WebsocketProxy(sourceConn, targetConn),
		sourceConn: sourceConn,
		targetConn: targetConn,
	}

	// Connect the data sockets
	for name := range sourceSecrets {
		if name == "control" {
			continue
		}

		// Handle resets (used for multiple objects)
		sourceConn, err := source.GetOperationWebsocket(sourceOp.ID, sourceSecrets[name])
		if err != nil {
			break
		}

		targetConn, err := r.GetOperationWebsocket(targetOp.ID, targetSecrets[name])
		if err != nil {
			break
		}

		proxies[name] = &proxy{
			sourceConn: sourceConn,
			targetConn: targetConn,
			done:       shared.WebsocketProxy(sourceConn, targetConn),
		}
	}

	// Cleanup once everything is done
	go func() {
		// Wait for control socket
		<-proxies["control"].done
		proxies["control"].sourceConn.Close()
		proxies["control"].targetConn.Close()

		// Then deal with the others
		for name, proxy := range proxies {
			if name == "control" {
				continue
			}

			<-proxy.done
			proxy.sourceConn.Close()
			proxy.targetConn.Close()
		}
	}()

	return nil
}

// UpdateContainer updates the container definition
func (r *ProtocolAPOLLO) UpdateContainer(name string, container api.ContainerPut, ETag string) (*Operation, error) {
	// Send the request
	op, _, err := r.queryOperation("PUT", fmt.Sprintf("/containers/%s", name), container, ETag)
	if err != nil {
		return nil, err
	}

	return op, nil
}

// RenameContainer requests that APOLLO renames the container
func (r *ProtocolAPOLLO) RenameContainer(name string, container api.ContainerPost) (*Operation, error) {
	// Sanity check
	if container.Migration {
		return nil, fmt.Errorf("Can't ask for a migration through RenameContainer")
	}

	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/containers/%s", name), container, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

func (r *ProtocolAPOLLO) tryMigrateContainer(source ContainerServer, name string, req api.ContainerPost, urls []string) (*RemoteOperation, error) {
	if len(urls) == 0 {
		return nil, fmt.Errorf("The target server isn't listening on the network")
	}

	rop := RemoteOperation{
		chDone: make(chan bool),
	}

	operation := req.Target.Operation

	// Forward targetOp to remote op
	go func() {
		success := false
		errors := []string{}
		for _, serverURL := range urls {
			req.Target.Operation = fmt.Sprintf("%s/1.0/operations/%s", serverURL, operation)

			op, err := source.MigrateContainer(name, req)
			if err != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", serverURL, err))
				continue
			}

			rop.targetOp = op

			for _, handler := range rop.handlers {
				rop.targetOp.AddHandler(handler)
			}

			err = rop.targetOp.Wait()
			if err != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", serverURL, err))
				continue
			}

			success = true
			break
		}

		if !success {
			rop.err = fmt.Errorf("Failed container migration:\n - %s", strings.Join(errors, "\n - "))
		}

		close(rop.chDone)
	}()

	return &rop, nil
}

// MigrateContainer requests that APOLLO prepares for a container migration
func (r *ProtocolAPOLLO) MigrateContainer(name string, container api.ContainerPost) (*Operation, error) {
	if container.ContainerOnly {
		if !r.HasExtension("container_only_migration") {
			return nil, fmt.Errorf("The server is missing the required \"container_only_migration\" API extension")
		}
	}

	// Sanity check
	if !container.Migration {
		return nil, fmt.Errorf("Can't ask for a rename through MigrateContainer")
	}

	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/containers/%s", name), container, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// DeleteContainer requests that APOLLO deletes the container
func (r *ProtocolAPOLLO) DeleteContainer(name string) (*Operation, error) {
	// Send the request
	op, _, err := r.queryOperation("DELETE", fmt.Sprintf("/containers/%s", name), nil, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// ExecContainer requests that APOLLO spawns a command inside the container
func (r *ProtocolAPOLLO) ExecContainer(containerName string, exec api.ContainerExecPost, args *ContainerExecArgs) (*Operation, error) {
	if exec.RecordOutput {
		if !r.HasExtension("container_exec_recording") {
			return nil, fmt.Errorf("The server is missing the required \"container_exec_recording\" API extension")
		}
	}

	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/containers/%s/exec", containerName), exec, "")
	if err != nil {
		return nil, err
	}

	// Process additional arguments
	if args != nil {
		// Parse the fds
		fds := map[string]string{}

		value, ok := op.Metadata["fds"]
		if ok {
			values := value.(map[string]interface{})
			for k, v := range values {
				fds[k] = v.(string)
			}
		}

		// Call the control handler with a connection to the control socket
		if args.Control != nil && fds["control"] != "" {
			conn, err := r.GetOperationWebsocket(op.ID, fds["control"])
			if err != nil {
				return nil, err
			}

			go args.Control(conn)
		}

		if exec.Interactive {
			// Handle interactive sections
			if args.Stdin != nil && args.Stdout != nil {
				// Connect to the websocket
				conn, err := r.GetOperationWebsocket(op.ID, fds["0"])
				if err != nil {
					return nil, err
				}

				// And attach stdin and stdout to it
				go func() {
					shared.WebsocketSendStream(conn, args.Stdin, -1)
					<-shared.WebsocketRecvStream(args.Stdout, conn)
					conn.Close()

					if args.DataDone != nil {
						close(args.DataDone)
					}
				}()
			} else {
				if args.DataDone != nil {
					close(args.DataDone)
				}
			}
		} else {
			// Handle non-interactive sessions
			dones := map[int]chan bool{}
			conns := []*websocket.Conn{}

			// Handle stdin
			if fds["0"] != "" {
				conn, err := r.GetOperationWebsocket(op.ID, fds["0"])
				if err != nil {
					return nil, err
				}

				conns = append(conns, conn)
				dones[0] = shared.WebsocketSendStream(conn, args.Stdin, -1)
			}

			// Handle stdout
			if fds["1"] != "" {
				conn, err := r.GetOperationWebsocket(op.ID, fds["1"])
				if err != nil {
					return nil, err
				}

				conns = append(conns, conn)
				dones[1] = shared.WebsocketRecvStream(args.Stdout, conn)
			}

			// Handle stderr
			if fds["2"] != "" {
				conn, err := r.GetOperationWebsocket(op.ID, fds["2"])
				if err != nil {
					return nil, err
				}

				conns = append(conns, conn)
				dones[2] = shared.WebsocketRecvStream(args.Stderr, conn)
			}

			// Wait for everything to be done
			go func() {
				for i, chDone := range dones {
					// Skip stdin, dealing with it separately below
					if i == 0 {
						continue
					}

					<-chDone
				}

				if fds["0"] != "" {
					args.Stdin.Close()
				}

				for _, conn := range conns {
					conn.Close()
				}

				if args.DataDone != nil {
					close(args.DataDone)
				}
			}()
		}
	}

	return op, nil
}

// GetContainerFile retrieves the provided path from the container
func (r *ProtocolAPOLLO) GetContainerFile(containerName string, path string) (io.ReadCloser, *ContainerFileResponse, error) {
	// Prepare the HTTP request
	requestURL, err := shared.URLEncode(
		fmt.Sprintf("%s/1.0/containers/%s/files", r.httpHost, containerName),
		map[string]string{"path": path})
	if err != nil {
		return nil, nil, err
	}

	req, err := http.NewRequest("GET", requestURL, nil)
	if err != nil {
		return nil, nil, err
	}

	// Set the user agent
	if r.httpUserAgent != "" {
		req.Header.Set("User-Agent", r.httpUserAgent)
	}

	// Send the request
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, nil, err
	}

	// Check the return value for a cleaner error
	if resp.StatusCode != http.StatusOK {
		_, _, err := r.parseResponse(resp)
		if err != nil {
			return nil, nil, err
		}
	}

	// Parse the headers
	uid, gid, mode, fileType, _ := shared.ParseAPOLLOFileHeaders(resp.Header)
	fileResp := ContainerFileResponse{
		UID:  uid,
		GID:  gid,
		Mode: mode,
		Type: fileType,
	}

	if fileResp.Type == "directory" {
		// Decode the response
		response := api.Response{}
		decoder := json.NewDecoder(resp.Body)

		err = decoder.Decode(&response)
		if err != nil {
			return nil, nil, err
		}

		// Get the file list
		entries := []string{}
		err = response.MetadataAsStruct(&entries)
		if err != nil {
			return nil, nil, err
		}

		fileResp.Entries = entries

		return nil, &fileResp, err
	}

	return resp.Body, &fileResp, err
}

// CreateContainerFile tells APOLLO to create a file in the container
func (r *ProtocolAPOLLO) CreateContainerFile(containerName string, path string, args ContainerFileArgs) error {
	if args.Type == "directory" {
		if !r.HasExtension("directory_manipulation") {
			return fmt.Errorf("The server is missing the required \"directory_manipulation\" API extension")
		}
	}

	if args.Type == "symlink" {
		if !r.HasExtension("file_symlinks") {
			return fmt.Errorf("The server is missing the required \"file_symlinks\" API extension")
		}
	}

	if args.WriteMode == "append" {
		if !r.HasExtension("file_append") {
			return fmt.Errorf("The server is missing the required \"file_append\" API extension")
		}
	}

	// Prepare the HTTP request
	requestURL, err := shared.URLEncode(
		fmt.Sprintf("%s/1.0/containers/%s/files", r.httpHost, containerName),
		map[string]string{"path": path})
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", requestURL, args.Content)
	if err != nil {
		return err
	}

	// Set the user agent
	if r.httpUserAgent != "" {
		req.Header.Set("User-Agent", r.httpUserAgent)
	}

	// Set the various headers
	if args.UID > -1 {
		req.Header.Set("X-APOLLO-uid", fmt.Sprintf("%d", args.UID))
	}

	if args.GID > -1 {
		req.Header.Set("X-APOLLO-gid", fmt.Sprintf("%d", args.GID))
	}

	if args.Mode > -1 {
		req.Header.Set("X-APOLLO-mode", fmt.Sprintf("%04o", args.Mode))
	}

	if args.Type != "" {
		req.Header.Set("X-APOLLO-type", args.Type)
	}

	if args.WriteMode != "" {
		req.Header.Set("X-APOLLO-write", args.WriteMode)
	}

	// Send the request
	resp, err := r.http.Do(req)
	if err != nil {
		return err
	}

	// Check the return value for a cleaner error
	_, _, err = r.parseResponse(resp)
	if err != nil {
		return err
	}

	return nil
}

// DeleteContainerFile deletes a file in the container
func (r *ProtocolAPOLLO) DeleteContainerFile(containerName string, path string) error {
	if !r.HasExtension("file_delete") {
		return fmt.Errorf("The server is missing the required \"file_delete\" API extension")
	}

	// Send the request
	_, _, err := r.query("DELETE", fmt.Sprintf("/containers/%s/files?path=%s", containerName, path), nil, "")
	if err != nil {
		return err
	}

	return nil
}

// GetContainerSnapshotNames returns a list of snapshot names for the container
func (r *ProtocolAPOLLO) GetContainerSnapshotNames(containerName string) ([]string, error) {
	urls := []string{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", fmt.Sprintf("/containers/%s/snapshots", containerName), nil, "", &urls)
	if err != nil {
		return nil, err
	}

	// Parse it
	names := []string{}
	for _, url := range urls {
		fields := strings.Split(url, fmt.Sprintf("/containers/%s/snapshots/", containerName))
		names = append(names, fields[len(fields)-1])
	}

	return names, nil
}

// GetContainerSnapshots returns a list of snapshots for the container
func (r *ProtocolAPOLLO) GetContainerSnapshots(containerName string) ([]api.ContainerSnapshot, error) {
	snapshots := []api.ContainerSnapshot{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", fmt.Sprintf("/containers/%s/snapshots?recursion=1", containerName), nil, "", &snapshots)
	if err != nil {
		return nil, err
	}

	return snapshots, nil
}

// GetContainerSnapshot returns a Snapshot struct for the provided container and snapshot names
func (r *ProtocolAPOLLO) GetContainerSnapshot(containerName string, name string) (*api.ContainerSnapshot, string, error) {
	snapshot := api.ContainerSnapshot{}

	// Fetch the raw value
	etag, err := r.queryStruct("GET", fmt.Sprintf("/containers/%s/snapshots/%s", containerName, name), nil, "", &snapshot)
	if err != nil {
		return nil, "", err
	}

	return &snapshot, etag, nil
}

// CreateContainerSnapshot requests that APOLLO creates a new snapshot for the container
func (r *ProtocolAPOLLO) CreateContainerSnapshot(containerName string, snapshot api.ContainerSnapshotsPost) (*Operation, error) {
	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/containers/%s/snapshots", containerName), snapshot, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// CopyContainerSnapshot copies a snapshot from a remote server into a new container. Additional options can be passed using ContainerCopyArgs
func (r *ProtocolAPOLLO) CopyContainerSnapshot(source ContainerServer, snapshot api.ContainerSnapshot, args *ContainerSnapshotCopyArgs) (*RemoteOperation, error) {
	// Base request
	fields := strings.SplitN(snapshot.Name, shared.SnapshotDelimiter, 2)
	cName := fields[0]
	sName := fields[1]

	req := api.ContainersPost{
		Name: cName,
		ContainerPut: api.ContainerPut{
			Architecture: snapshot.Architecture,
			Config:       snapshot.Config,
			Devices:      snapshot.Devices,
			Ephemeral:    snapshot.Ephemeral,
			Profiles:     snapshot.Profiles,
		},
	}

	if snapshot.Stateful && args.Live {
		if !r.HasExtension("container_snapshot_stateful_migration") {
			return nil, fmt.Errorf("The server is missing the required \"container_snapshot_stateful_migration\" API extension")
		}
		req.ContainerPut.Stateful = snapshot.Stateful
		req.Source.Live = args.Live
	}
	req.Source.BaseImage = snapshot.Config["volatile.base_image"]

	// Process the copy arguments
	if args != nil {
		// Sanity checks
		if shared.StringInSlice(args.Mode, []string{"push", "relay"}) {
			if !r.HasExtension("container_push") {
				return nil, fmt.Errorf("The target server is missing the required \"container_push\" API extension")
			}

			if !source.HasExtension("container_push") {
				return nil, fmt.Errorf("The source server is missing the required \"container_push\" API extension")
			}
		}

		if args.Mode == "push" && !source.HasExtension("container_push_target") {
			return nil, fmt.Errorf("The source server is missing the required \"container_push_target\" API extension")
		}

		// Allow overriding the target name
		if args.Name != "" {
			req.Name = args.Name
		}
	}

	// Optimization for the local copy case
	if r == source {
		// Local copy source fields
		req.Source.Type = "copy"
		req.Source.Source = snapshot.Name

		// Copy the container
		op, err := r.CreateContainer(req)
		if err != nil {
			return nil, err
		}

		rop := RemoteOperation{
			targetOp: op,
			chDone:   make(chan bool),
		}

		// Forward targetOp to remote op
		go func() {
			rop.err = rop.targetOp.Wait()
			close(rop.chDone)
		}()

		return &rop, nil
	}

	// Source request
	sourceReq := api.ContainerSnapshotPost{
		Migration: true,
		Name:      args.Name,
	}
	if snapshot.Stateful && args.Live {
		sourceReq.Live = args.Live
	}

	// Push mode migration
	if args != nil && args.Mode == "push" {
		// Get target server connection information
		info, err := r.GetConnectionInfo()
		if err != nil {
			return nil, err
		}

		// Create the container
		req.Source.Type = "migration"
		req.Source.Mode = "push"

		op, err := r.CreateContainer(req)
		if err != nil {
			return nil, err
		}

		targetSecrets := map[string]string{}
		for k, v := range op.Metadata {
			targetSecrets[k] = v.(string)
		}

		// Prepare the source request
		target := api.ContainerPostTarget{}
		target.Operation = op.ID
		target.Websockets = targetSecrets
		target.Certificate = info.Certificate
		sourceReq.Target = &target

		return r.tryMigrateContainerSnapshot(source, cName, sName, sourceReq, info.Addresses)
	}

	// Get source server connection information
	info, err := source.GetConnectionInfo()
	if err != nil {
		return nil, err
	}

	op, err := source.MigrateContainerSnapshot(cName, sName, sourceReq)
	if err != nil {
		return nil, err
	}

	sourceSecrets := map[string]string{}
	for k, v := range op.Metadata {
		sourceSecrets[k] = v.(string)
	}

	// Relay mode migration
	if args != nil && args.Mode == "relay" {
		// Push copy source fields
		req.Source.Type = "migration"
		req.Source.Mode = "push"

		// Start the process
		targetOp, err := r.CreateContainer(req)
		if err != nil {
			return nil, err
		}

		// Extract the websockets
		targetSecrets := map[string]string{}
		for k, v := range targetOp.Metadata {
			targetSecrets[k] = v.(string)
		}

		// Launch the relay
		err = r.proxyMigration(targetOp, targetSecrets, source, op, sourceSecrets)
		if err != nil {
			return nil, err
		}

		// Prepare a tracking operation
		rop := RemoteOperation{
			targetOp: targetOp,
			chDone:   make(chan bool),
		}

		// Forward targetOp to remote op
		go func() {
			rop.err = rop.targetOp.Wait()
			close(rop.chDone)
		}()

		return &rop, nil
	}

	// Pull mode migration
	req.Source.Type = "migration"
	req.Source.Mode = "pull"
	req.Source.Operation = op.ID
	req.Source.Websockets = sourceSecrets
	req.Source.Certificate = info.Certificate

	return r.tryCreateContainer(req, info.Addresses)
}

// RenameContainerSnapshot requests that APOLLO renames the snapshot
func (r *ProtocolAPOLLO) RenameContainerSnapshot(containerName string, name string, container api.ContainerSnapshotPost) (*Operation, error) {
	// Sanity check
	if container.Migration {
		return nil, fmt.Errorf("Can't ask for a migration through RenameContainerSnapshot")
	}

	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/containers/%s/snapshots/%s", containerName, name), container, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

func (r *ProtocolAPOLLO) tryMigrateContainerSnapshot(source ContainerServer, containerName string, name string, req api.ContainerSnapshotPost, urls []string) (*RemoteOperation, error) {
	if len(urls) == 0 {
		return nil, fmt.Errorf("The target server isn't listening on the network")
	}

	rop := RemoteOperation{
		chDone: make(chan bool),
	}

	operation := req.Target.Operation

	// Forward targetOp to remote op
	go func() {
		success := false
		errors := []string{}
		for _, serverURL := range urls {
			req.Target.Operation = fmt.Sprintf("%s/1.0/operations/%s", serverURL, operation)

			op, err := source.MigrateContainerSnapshot(containerName, name, req)
			if err != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", serverURL, err))
				continue
			}

			rop.targetOp = op

			for _, handler := range rop.handlers {
				rop.targetOp.AddHandler(handler)
			}

			err = rop.targetOp.Wait()
			if err != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", serverURL, err))
				continue
			}

			success = true
			break
		}

		if !success {
			rop.err = fmt.Errorf("Failed container migration:\n - %s", strings.Join(errors, "\n - "))
		}

		close(rop.chDone)
	}()

	return &rop, nil
}

// MigrateContainerSnapshot requests that APOLLO prepares for a snapshot migration
func (r *ProtocolAPOLLO) MigrateContainerSnapshot(containerName string, name string, container api.ContainerSnapshotPost) (*Operation, error) {
	// Sanity check
	if !container.Migration {
		return nil, fmt.Errorf("Can't ask for a rename through MigrateContainerSnapshot")
	}

	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/containers/%s/snapshots/%s", containerName, name), container, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// DeleteContainerSnapshot requests that APOLLO deletes the container snapshot
func (r *ProtocolAPOLLO) DeleteContainerSnapshot(containerName string, name string) (*Operation, error) {
	// Send the request
	op, _, err := r.queryOperation("DELETE", fmt.Sprintf("/containers/%s/snapshots/%s", containerName, name), nil, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// GetContainerState returns a ContainerState entry for the provided container name
func (r *ProtocolAPOLLO) GetContainerState(name string) (*api.ContainerState, string, error) {
	state := api.ContainerState{}

	// Fetch the raw value
	etag, err := r.queryStruct("GET", fmt.Sprintf("/containers/%s/state", name), nil, "", &state)
	if err != nil {
		return nil, "", err
	}

	return &state, etag, nil
}

// UpdateContainerState updates the container to match the requested state
func (r *ProtocolAPOLLO) UpdateContainerState(name string, state api.ContainerStatePut, ETag string) (*Operation, error) {
	// Send the request
	op, _, err := r.queryOperation("PUT", fmt.Sprintf("/containers/%s/state", name), state, ETag)
	if err != nil {
		return nil, err
	}

	return op, nil
}

// GetContainerLogfiles returns a list of logfiles for the container
func (r *ProtocolAPOLLO) GetContainerLogfiles(name string) ([]string, error) {
	urls := []string{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", fmt.Sprintf("/containers/%s/logs", name), nil, "", &urls)
	if err != nil {
		return nil, err
	}

	// Parse it
	logfiles := []string{}
	for _, url := range logfiles {
		fields := strings.Split(url, fmt.Sprintf("/containers/%s/logs/", name))
		logfiles = append(logfiles, fields[len(fields)-1])
	}

	return logfiles, nil
}

// GetContainerLogfile returns the content of the requested logfile
//
// Note that it's the caller's responsibility to close the returned ReadCloser
func (r *ProtocolAPOLLO) GetContainerLogfile(name string, filename string) (io.ReadCloser, error) {
	// Prepare the HTTP request
	url := fmt.Sprintf("%s/1.0/containers/%s/logs/%s", r.httpHost, name, filename)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	// Set the user agent
	if r.httpUserAgent != "" {
		req.Header.Set("User-Agent", r.httpUserAgent)
	}

	// Send the request
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, err
	}

	// Check the return value for a cleaner error
	if resp.StatusCode != http.StatusOK {
		_, _, err := r.parseResponse(resp)
		if err != nil {
			return nil, err
		}
	}

	return resp.Body, err
}

// DeleteContainerLogfile deletes the requested logfile
func (r *ProtocolAPOLLO) DeleteContainerLogfile(name string, filename string) error {
	// Send the request
	_, _, err := r.query("DELETE", fmt.Sprintf("/containers/%s/logs/%s", name, filename), nil, "")
	if err != nil {
		return err
	}

	return nil
}

// GetContainerMetadata returns container metadata.
func (r *ProtocolAPOLLO) GetContainerMetadata(name string) (*api.ImageMetadata, string, error) {
	if !r.HasExtension("container_edit_metadata") {
		return nil, "", fmt.Errorf("The server is missing the required \"container_edit_metadata\" API extension")
	}

	metadata := api.ImageMetadata{}

	url := fmt.Sprintf("/containers/%s/metadata", name)
	etag, err := r.queryStruct("GET", url, nil, "", &metadata)
	if err != nil {
		return nil, "", err
	}

	return &metadata, etag, err
}

// SetContainerMetadata sets the content of the container metadata file.
func (r *ProtocolAPOLLO) SetContainerMetadata(name string, metadata api.ImageMetadata, ETag string) error {
	if !r.HasExtension("container_edit_metadata") {
		return fmt.Errorf("The server is missing the required \"container_edit_metadata\" API extension")
	}

	url := fmt.Sprintf("/containers/%s/metadata", name)
	_, _, err := r.query("PUT", url, metadata, ETag)
	if err != nil {
		return err
	}

	return nil
}

// GetContainerTemplateFiles returns the list of names of template files for a container.
func (r *ProtocolAPOLLO) GetContainerTemplateFiles(containerName string) ([]string, error) {
	if !r.HasExtension("container_edit_metadata") {
		return nil, fmt.Errorf("The server is missing the required \"container_edit_metadata\" API extension")
	}

	templates := []string{}

	url := fmt.Sprintf("/containers/%s/metadata/templates", containerName)
	_, err := r.queryStruct("GET", url, nil, "", &templates)
	if err != nil {
		return nil, err
	}

	return templates, nil
}

// GetContainerTemplateFile returns the content of a template file for a container.
func (r *ProtocolAPOLLO) GetContainerTemplateFile(containerName string, templateName string) (io.ReadCloser, error) {
	if !r.HasExtension("container_edit_metadata") {
		return nil, fmt.Errorf("The server is missing the required \"container_edit_metadata\" API extension")
	}

	url := fmt.Sprintf("%s/1.0/containers/%s/metadata/templates?path=%s", r.httpHost, containerName, templateName)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	// Set the user agent
	if r.httpUserAgent != "" {
		req.Header.Set("User-Agent", r.httpUserAgent)
	}

	// Send the request
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, err
	}

	// Check the return value for a cleaner error
	if resp.StatusCode != http.StatusOK {
		_, _, err := r.parseResponse(resp)
		if err != nil {
			return nil, err
		}
	}

	return resp.Body, err
}

// CreateContainerTemplateFile creates an a template for a container.
func (r *ProtocolAPOLLO) CreateContainerTemplateFile(containerName string, templateName string, content io.ReadSeeker) error {
	return r.setContainerTemplateFile(containerName, templateName, content, "POST")
}

// UpdateContainerTemplateFile updates the content for a container template file.
func (r *ProtocolAPOLLO) UpdateContainerTemplateFile(containerName string, templateName string, content io.ReadSeeker) error {
	return r.setContainerTemplateFile(containerName, templateName, content, "PUT")
}

func (r *ProtocolAPOLLO) setContainerTemplateFile(containerName string, templateName string, content io.ReadSeeker, httpMethod string) error {
	if !r.HasExtension("container_edit_metadata") {
		return fmt.Errorf("The server is missing the required \"container_edit_metadata\" API extension")
	}

	url := fmt.Sprintf("%s/1.0/containers/%s/metadata/templates?path=%s", r.httpHost, containerName, templateName)
	req, err := http.NewRequest(httpMethod, url, content)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/octet-stream")

	// Set the user agent
	if r.httpUserAgent != "" {
		req.Header.Set("User-Agent", r.httpUserAgent)
	}

	// Send the request
	resp, err := r.http.Do(req)
	// Check the return value for a cleaner error
	if resp.StatusCode != http.StatusOK {
		_, _, err := r.parseResponse(resp)
		if err != nil {
			return err
		}
	}
	return err
}

// DeleteContainerTemplateFile deletes a template file for a container.
func (r *ProtocolAPOLLO) DeleteContainerTemplateFile(name string, templateName string) error {
	if !r.HasExtension("container_edit_metadata") {
		return fmt.Errorf("The server is missing the required \"container_edit_metadata\" API extension")
	}
	_, _, err := r.query("DELETE", fmt.Sprintf("/containers/%s/metadata/templates?path=%s", name, templateName), nil, "")
	return err
}
