package api

// ServerEnvironment represents the read-only environment fields of a APOLLO server
type ServerEnvironment struct {
	Addresses              []string `json:"addresses" yaml:"addresses"`
	Architectures          []string `json:"architectures" yaml:"architectures"`
	Certificate            string   `json:"certificate" yaml:"certificate"`
	CertificateFingerprint string   `json:"certificate_fingerprint" yaml:"certificate_fingerprint"`
	Driver                 string   `json:"driver" yaml:"driver"`
	DriverVersion          string   `json:"driver_version" yaml:"driver_version"`
	Kernel                 string   `json:"kernel" yaml:"kernel"`
	KernelArchitecture     string   `json:"kernel_architecture" yaml:"kernel_architecture"`
	KernelVersion          string   `json:"kernel_version" yaml:"kernel_version"`
	Server                 string   `json:"server" yaml:"server"`
	ServerPid              int      `json:"server_pid" yaml:"server_pid"`
	ServerVersion          string   `json:"server_version" yaml:"server_version"`
	Storage                string   `json:"storage" yaml:"storage"`
	StorageVersion         string   `json:"storage_version" yaml:"storage_version"`
}

// ServerPut represents the modifiable fields of a APOLLO server configuration
type ServerPut struct {
	Config map[string]interface{} `json:"config" yaml:"config"`
}

// ServerUntrusted represents a APOLLO server for an untrusted client
type ServerUntrusted struct {
	APIExtensions []string `json:"api_extensions" yaml:"api_extensions"`
	APIStatus     string   `json:"api_status" yaml:"api_status"`
	APIVersion    string   `json:"api_version" yaml:"api_version"`
	Auth          string   `json:"auth" yaml:"auth"`
	Public        bool     `json:"public" yaml:"public"`
}

// Server represents a APOLLO server
type Server struct {
	ServerPut       `yaml:",inline"`
	ServerUntrusted `yaml:",inline"`

	Environment ServerEnvironment `json:"environment" yaml:"environment"`
}

// Writable converts a full Server struct into a ServerPut struct (filters read-only fields)
func (srv *Server) Writable() ServerPut {
	return srv.ServerPut
}
