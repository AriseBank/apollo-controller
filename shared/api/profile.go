package api

// ProfilesPost represents the fields of a new APOLLO profile
type ProfilesPost struct {
	ProfilePut `yaml:",inline"`

	Name string `json:"name" yaml:"name"`
}

// ProfilePost represents the fields required to rename a APOLLO profile
type ProfilePost struct {
	Name string `json:"name" yaml:"name"`
}

// ProfilePut represents the modifiable fields of a APOLLO profile
type ProfilePut struct {
	Config      map[string]string            `json:"config" yaml:"config"`
	Description string                       `json:"description" yaml:"description"`
	Devices     map[string]map[string]string `json:"devices" yaml:"devices"`
}

// Profile represents a APOLLO profile
type Profile struct {
	ProfilePut `yaml:",inline"`

	Name string `json:"name" yaml:"name"`

	// API extension: profile_usedby
	UsedBy []string `json:"used_by" yaml:"used_by"`
}

// Writable converts a full Profile struct into a ProfilePut struct (filters read-only fields)
func (profile *Profile) Writable() ProfilePut {
	return profile.ProfilePut
}
