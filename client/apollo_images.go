package apollo

import (
	"crypto/sha256"
	"fmt"
	"io"
	"io/ioutil"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/AriseBank/apollo-controller/shared"
	"github.com/AriseBank/apollo-controller/shared/api"
	"github.com/AriseBank/apollo-controller/shared/cancel"
	"github.com/AriseBank/apollo-controller/shared/ioprogress"
)

// Image handling functions

// GetImages returns a list of available images as Image structs
func (r *ProtocolAPOLLO) GetImages() ([]api.Image, error) {
	images := []api.Image{}

	_, err := r.queryStruct("GET", "/images?recursion=1", nil, "", &images)
	if err != nil {
		return nil, err
	}

	return images, nil
}

// GetImageFingerprints returns a list of available image fingerprints
func (r *ProtocolAPOLLO) GetImageFingerprints() ([]string, error) {
	urls := []string{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", "/images", nil, "", &urls)
	if err != nil {
		return nil, err
	}

	// Parse it
	fingerprints := []string{}
	for _, url := range urls {
		fields := strings.Split(url, "/images/")
		fingerprints = append(fingerprints, fields[len(fields)-1])
	}

	return fingerprints, nil
}

// GetImage returns an Image struct for the provided fingerprint
func (r *ProtocolAPOLLO) GetImage(fingerprint string) (*api.Image, string, error) {
	return r.GetPrivateImage(fingerprint, "")
}

// GetImageFile downloads an image from the server, returning an ImageFileRequest struct
func (r *ProtocolAPOLLO) GetImageFile(fingerprint string, req ImageFileRequest) (*ImageFileResponse, error) {
	return r.GetPrivateImageFile(fingerprint, "", req)
}

// GetImageSecret is a helper around CreateImageSecret that returns a secret for the image
func (r *ProtocolAPOLLO) GetImageSecret(fingerprint string) (string, error) {
	op, err := r.CreateImageSecret(fingerprint)
	if err != nil {
		return "", err
	}

	return op.Metadata["secret"].(string), nil
}

// GetPrivateImage is similar to GetImage but allows passing a secret download token
func (r *ProtocolAPOLLO) GetPrivateImage(fingerprint string, secret string) (*api.Image, string, error) {
	image := api.Image{}

	// Build the API path
	path := fmt.Sprintf("/images/%s", fingerprint)
	if secret != "" {
		path = fmt.Sprintf("%s?secret=%s", path, secret)
	}

	// Fetch the raw value
	etag, err := r.queryStruct("GET", path, nil, "", &image)
	if err != nil {
		return nil, "", err
	}

	return &image, etag, nil
}

// GetPrivateImageFile is similar to GetImageFile but allows passing a secret download token
func (r *ProtocolAPOLLO) GetPrivateImageFile(fingerprint string, secret string, req ImageFileRequest) (*ImageFileResponse, error) {
	// Sanity checks
	if req.MetaFile == nil && req.RootfsFile == nil {
		return nil, fmt.Errorf("No file requested")
	}

	// Prepare the response
	resp := ImageFileResponse{}

	// Build the URL
	url := fmt.Sprintf("%s/1.0/images/%s/export", r.httpHost, fingerprint)
	if secret != "" {
		url = fmt.Sprintf("%s?secret=%s", url, secret)
	}

	// Prepare the download request
	request, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}

	if r.httpUserAgent != "" {
		request.Header.Set("User-Agent", r.httpUserAgent)
	}

	// Start the request
	response, doneCh, err := cancel.CancelableDownload(req.Canceler, r.http, request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	defer close(doneCh)

	if response.StatusCode != http.StatusOK {
		_, _, err := r.parseResponse(response)
		if err != nil {
			return nil, err
		}
	}

	ctype, ctypeParams, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil {
		ctype = "application/octet-stream"
	}

	// Handle the data
	body := response.Body
	if req.ProgressHandler != nil {
		body = &ioprogress.ProgressReader{
			ReadCloser: response.Body,
			Tracker: &ioprogress.ProgressTracker{
				Length: response.ContentLength,
				Handler: func(percent int64, speed int64) {
					req.ProgressHandler(ProgressData{Text: fmt.Sprintf("%d%% (%s/s)", percent, shared.GetByteSizeString(speed, 2))})
				},
			},
		}
	}

	// Hashing
	sha256 := sha256.New()

	// Deal with split images
	if ctype == "multipart/form-data" {
		if req.MetaFile == nil || req.RootfsFile == nil {
			return nil, fmt.Errorf("Multi-part image but only one target file provided")
		}

		// Parse the POST data
		mr := multipart.NewReader(body, ctypeParams["boundary"])

		// Get the metadata tarball
		part, err := mr.NextPart()
		if err != nil {
			return nil, err
		}

		if part.FormName() != "metadata" {
			return nil, fmt.Errorf("Invalid multipart image")
		}

		size, err := io.Copy(io.MultiWriter(req.MetaFile, sha256), part)
		if err != nil {
			return nil, err
		}
		resp.MetaSize = size
		resp.MetaName = part.FileName()

		// Get the rootfs tarball
		part, err = mr.NextPart()
		if err != nil {
			return nil, err
		}

		if part.FormName() != "rootfs" {
			return nil, fmt.Errorf("Invalid multipart image")
		}

		size, err = io.Copy(io.MultiWriter(req.RootfsFile, sha256), part)
		if err != nil {
			return nil, err
		}
		resp.RootfsSize = size
		resp.RootfsName = part.FileName()

		// Check the hash
		hash := fmt.Sprintf("%x", sha256.Sum(nil))
		if !strings.HasPrefix(hash, fingerprint) {
			return nil, fmt.Errorf("Image fingerprint doesn't match. Got %s expected %s", hash, fingerprint)
		}

		return &resp, nil
	}

	// Deal with unified images
	_, cdParams, err := mime.ParseMediaType(response.Header.Get("Content-Disposition"))
	if err != nil {
		return nil, err
	}

	filename, ok := cdParams["filename"]
	if !ok {
		return nil, fmt.Errorf("No filename in Content-Disposition header")
	}

	size, err := io.Copy(io.MultiWriter(req.MetaFile, sha256), body)
	if err != nil {
		return nil, err
	}
	resp.MetaSize = size
	resp.MetaName = filename

	// Check the hash
	hash := fmt.Sprintf("%x", sha256.Sum(nil))
	if !strings.HasPrefix(hash, fingerprint) {
		return nil, fmt.Errorf("Image fingerprint doesn't match. Got %s expected %s", hash, fingerprint)
	}

	return &resp, nil
}

// GetImageAliases returns the list of available aliases as ImageAliasesEntry structs
func (r *ProtocolAPOLLO) GetImageAliases() ([]api.ImageAliasesEntry, error) {
	aliases := []api.ImageAliasesEntry{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", "/images/aliases?recursion=1", nil, "", &aliases)
	if err != nil {
		return nil, err
	}

	return aliases, nil
}

// GetImageAliasNames returns the list of available alias names
func (r *ProtocolAPOLLO) GetImageAliasNames() ([]string, error) {
	urls := []string{}

	// Fetch the raw value
	_, err := r.queryStruct("GET", "/images/aliases", nil, "", &urls)
	if err != nil {
		return nil, err
	}

	// Parse it
	names := []string{}
	for _, url := range urls {
		fields := strings.Split(url, "/images/aliases/")
		names = append(names, fields[len(fields)-1])
	}

	return names, nil
}

// GetImageAlias returns an existing alias as an ImageAliasesEntry struct
func (r *ProtocolAPOLLO) GetImageAlias(name string) (*api.ImageAliasesEntry, string, error) {
	alias := api.ImageAliasesEntry{}

	// Fetch the raw value
	etag, err := r.queryStruct("GET", fmt.Sprintf("/images/aliases/%s", name), nil, "", &alias)
	if err != nil {
		return nil, "", err
	}

	return &alias, etag, nil
}

// CreateImage requests that APOLLO creates, copies or import a new image
func (r *ProtocolAPOLLO) CreateImage(image api.ImagesPost, args *ImageCreateArgs) (*Operation, error) {
	if image.CompressionAlgorithm != "" {
		if !r.HasExtension("image_compression_algorithm") {
			return nil, fmt.Errorf("The server is missing the required \"image_compression_algorithm\" API extension")
		}
	}

	// Send the JSON based request
	if args == nil {
		op, _, err := r.queryOperation("POST", "/images", image, "")
		if err != nil {
			return nil, err
		}

		return op, nil
	}

	// Prepare an image upload
	if args.MetaFile == nil {
		return nil, fmt.Errorf("Metadata file is required")
	}

	// Prepare the body
	var body io.Reader
	var contentType string
	if args.RootfsFile == nil {
		// If unified image, just pass it through
		body = args.MetaFile

		contentType = "application/octet-stream"
	} else {
		// If split image, we need mime encoding
		tmpfile, err := ioutil.TempFile("", "mercury_image_")
		if err != nil {
			return nil, err
		}
		defer os.Remove(tmpfile.Name())

		// Setup the multipart writer
		w := multipart.NewWriter(tmpfile)

		// Metadata file
		fw, err := w.CreateFormFile("metadata", args.MetaName)
		if err != nil {
			return nil, err
		}

		_, err = io.Copy(fw, args.MetaFile)
		if err != nil {
			return nil, err
		}

		// Rootfs file
		fw, err = w.CreateFormFile("rootfs", args.RootfsName)
		if err != nil {
			return nil, err
		}

		_, err = io.Copy(fw, args.RootfsFile)
		if err != nil {
			return nil, err
		}

		// Done writing to multipart
		w.Close()

		// Figure out the size of the whole thing
		size, err := tmpfile.Seek(0, 2)
		if err != nil {
			return nil, err
		}

		_, err = tmpfile.Seek(0, 0)
		if err != nil {
			return nil, err
		}

		// Setup progress handler
		body = &ioprogress.ProgressReader{
			ReadCloser: tmpfile,
			Tracker: &ioprogress.ProgressTracker{
				Length: size,
				Handler: func(percent int64, speed int64) {
					args.ProgressHandler(ProgressData{Text: fmt.Sprintf("%d%% (%s/s)", percent, shared.GetByteSizeString(speed, 2))})
				},
			},
		}

		contentType = w.FormDataContentType()
	}

	// Prepare the HTTP request
	reqURL := fmt.Sprintf("%s/1.0/images", r.httpHost)
	req, err := http.NewRequest("POST", reqURL, body)
	if err != nil {
		return nil, err
	}

	// Setup the headers
	req.Header.Set("Content-Type", contentType)
	if image.Public {
		req.Header.Set("X-APOLLO-public", "true")
	}

	if image.Filename != "" {
		req.Header.Set("X-APOLLO-filename", image.Filename)
	}

	if len(image.Properties) > 0 {
		imgProps := url.Values{}

		for k, v := range image.Properties {
			imgProps.Set(k, v)
		}

		req.Header.Set("X-APOLLO-properties", imgProps.Encode())
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
	defer resp.Body.Close()

	// Handle errors
	response, _, err := r.parseResponse(resp)
	if err != nil {
		return nil, err
	}

	// Get to the operation
	respOperation, err := response.MetadataAsOperation()
	if err != nil {
		return nil, err
	}

	// Setup an Operation wrapper
	op := Operation{
		Operation: *respOperation,
		r:         r,
		chActive:  make(chan bool),
	}

	return &op, nil
}

// tryCopyImage iterates through the source server URLs until one lets it download the image
func (r *ProtocolAPOLLO) tryCopyImage(req api.ImagesPost, urls []string) (*RemoteOperation, error) {
	if len(urls) == 0 {
		return nil, fmt.Errorf("The source server isn't listening on the network")
	}

	rop := RemoteOperation{
		chDone: make(chan bool),
	}

	// For older servers, apply the aliases after copy
	if !r.HasExtension("image_create_aliases") && req.Aliases != nil {
		rop.chPost = make(chan bool)

		go func() {
			defer close(rop.chPost)

			// Wait for the main operation to finish
			<-rop.chDone
			if rop.err != nil {
				return
			}

			// Get the operation data
			op, err := rop.GetTarget()
			if err != nil {
				return
			}

			// Extract the fingerprint
			fingerprint := op.Metadata["fingerprint"].(string)

			// Add the aliases
			for _, entry := range req.Aliases {
				alias := api.ImageAliasesPost{}
				alias.Name = entry.Name
				alias.Target = fingerprint

				r.CreateImageAlias(alias)
			}
		}()
	}

	// Forward targetOp to remote op
	go func() {
		success := false
		errors := []string{}
		for _, serverURL := range urls {
			req.Source.Server = serverURL

			op, err := r.CreateImage(req, nil)
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
			rop.err = fmt.Errorf("Failed remote image download:\n - %s", strings.Join(errors, "\n - "))
		}

		close(rop.chDone)
	}()

	return &rop, nil
}

// CopyImage copies an image from a remote server. Additional options can be passed using ImageCopyArgs
func (r *ProtocolAPOLLO) CopyImage(source ImageServer, image api.Image, args *ImageCopyArgs) (*RemoteOperation, error) {
	// Sanity checks
	if r == source {
		return nil, fmt.Errorf("The source and target servers must be different")
	}

	// Get source server connection information
	info, err := source.GetConnectionInfo()
	if err != nil {
		return nil, err
	}

	// Prepare the copy request
	req := api.ImagesPost{
		Source: &api.ImagesPostSource{
			ImageSource: api.ImageSource{
				Certificate: info.Certificate,
				Protocol:    info.Protocol,
			},
			Fingerprint: image.Fingerprint,
			Mode:        "pull",
			Type:        "image",
		},
	}

	// Generate secret token if needed
	if !image.Public {
		secret, err := source.GetImageSecret(image.Fingerprint)
		if err != nil {
			return nil, err
		}

		req.Source.Secret = secret
	}

	// Process the arguments
	if args != nil {
		req.Aliases = args.Aliases
		req.AutoUpdate = args.AutoUpdate
		req.Public = args.Public

		if args.CopyAliases {
			req.Aliases = image.Aliases
			if args.Aliases != nil {
				req.Aliases = append(req.Aliases, args.Aliases...)
			}
		}
	}

	return r.tryCopyImage(req, info.Addresses)
}

// UpdateImage updates the image definition
func (r *ProtocolAPOLLO) UpdateImage(fingerprint string, image api.ImagePut, ETag string) error {
	// Send the request
	_, _, err := r.query("PUT", fmt.Sprintf("/images/%s", fingerprint), image, ETag)
	if err != nil {
		return err
	}

	return nil
}

// DeleteImage requests that APOLLO removes an image from the store
func (r *ProtocolAPOLLO) DeleteImage(fingerprint string) (*Operation, error) {
	// Send the request
	op, _, err := r.queryOperation("DELETE", fmt.Sprintf("/images/%s", fingerprint), nil, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// RefreshImage requests that APOLLO issues an image refresh
func (r *ProtocolAPOLLO) RefreshImage(fingerprint string) (*Operation, error) {
	if !r.HasExtension("image_force_refresh") {
		return nil, fmt.Errorf("The server is missing the required \"image_force_refresh\" API extension")
	}

	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/images/%s/refresh", fingerprint), nil, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// CreateImageSecret requests that APOLLO issues a temporary image secret
func (r *ProtocolAPOLLO) CreateImageSecret(fingerprint string) (*Operation, error) {
	// Send the request
	op, _, err := r.queryOperation("POST", fmt.Sprintf("/images/%s/secret", fingerprint), nil, "")
	if err != nil {
		return nil, err
	}

	return op, nil
}

// CreateImageAlias sets up a new image alias
func (r *ProtocolAPOLLO) CreateImageAlias(alias api.ImageAliasesPost) error {
	// Send the request
	_, _, err := r.query("POST", "/images/aliases", alias, "")
	if err != nil {
		return err
	}

	return nil
}

// UpdateImageAlias updates the image alias definition
func (r *ProtocolAPOLLO) UpdateImageAlias(name string, alias api.ImageAliasesEntryPut, ETag string) error {
	// Send the request
	_, _, err := r.query("PUT", fmt.Sprintf("/images/aliases/%s", name), alias, ETag)
	if err != nil {
		return err
	}

	return nil
}

// RenameImageAlias renames an existing image alias
func (r *ProtocolAPOLLO) RenameImageAlias(name string, alias api.ImageAliasesEntryPost) error {
	// Send the request
	_, _, err := r.query("POST", fmt.Sprintf("/images/aliases/%s", name), alias, "")
	if err != nil {
		return err
	}

	return nil
}

// DeleteImageAlias removes an alias from the APOLLO image store
func (r *ProtocolAPOLLO) DeleteImageAlias(name string) error {
	// Send the request
	_, _, err := r.query("DELETE", fmt.Sprintf("/images/aliases/%s", name), nil, "")
	if err != nil {
		return err
	}

	return nil
}
