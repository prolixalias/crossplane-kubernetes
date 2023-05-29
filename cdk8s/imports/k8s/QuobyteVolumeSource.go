package k8s


// Represents a Quobyte mount that lasts the lifetime of a pod.
//
// Quobyte volumes do not support ownership management or SELinux relabeling.
type QuobyteVolumeSource struct {
	// registry represents a single or multiple Quobyte Registry services specified as a string as host:port pair (multiple entries are separated with commas) which acts as the central registry for volumes.
	Registry *string `field:"required" json:"registry" yaml:"registry"`
	// volume is a string that references an already created Quobyte volume by name.
	Volume *string `field:"required" json:"volume" yaml:"volume"`
	// group to map volume access to Default is no group.
	Group *string `field:"optional" json:"group" yaml:"group"`
	// readOnly here will force the Quobyte volume to be mounted with read-only permissions.
	//
	// Defaults to false.
	ReadOnly *bool `field:"optional" json:"readOnly" yaml:"readOnly"`
	// tenant owning the given Quobyte volume in the Backend Used with dynamically provisioned Quobyte volumes, value is set by the plugin.
	Tenant *string `field:"optional" json:"tenant" yaml:"tenant"`
	// user to map volume access to Defaults to serivceaccount user.
	User *string `field:"optional" json:"user" yaml:"user"`
}

