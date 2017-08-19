package api

// CertificatesPost represents the fields of a new APOLLO certificate
type CertificatesPost struct {
	CertificatePut `yaml:",inline"`

	Certificate string `json:"certificate" yaml:"certificate"`
	Password    string `json:"password" yaml:"password"`
}

// CertificatePut represents the modifiable fields of a APOLLO certificate
//
// API extension: certificate_update
type CertificatePut struct {
	Name string `json:"name" yaml:"name"`
	Type string `json:"type" yaml:"type"`
}

// Certificate represents a APOLLO certificate
type Certificate struct {
	CertificatePut `yaml:",inline"`

	Certificate string `json:"certificate" yaml:"certificate"`
	Fingerprint string `json:"fingerprint" yaml:"fingerprint"`
}

// Writable converts a full Certificate struct into a CertificatePut struct (filters read-only fields)
func (cert *Certificate) Writable() CertificatePut {
	return cert.CertificatePut
}
