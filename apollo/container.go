package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/AriseBank/go-mercury"

	"github.com/AriseBank/apollo-controller/apollo/db"
	"github.com/AriseBank/apollo-controller/apollo/types"
	"github.com/AriseBank/apollo-controller/shared"
	"github.com/AriseBank/apollo-controller/shared/api"
	"github.com/AriseBank/apollo-controller/shared/osarch"
)

// Helper functions

// Returns the parent container name, snapshot name, and whether it actually was
// a snapshot name.
func containerGetParentAndSnapshotName(name string) (string, string, bool) {
	fields := strings.SplitN(name, shared.SnapshotDelimiter, 2)
	if len(fields) == 1 {
		return name, "", false
	}

	return fields[0], fields[1], true
}

func containerPath(name string, isSnapshot bool) string {
	if isSnapshot {
		return shared.VarPath("snapshots", name)
	}

	return shared.VarPath("containers", name)
}

func containerValidName(name string) error {
	if strings.Contains(name, shared.SnapshotDelimiter) {
		return fmt.Errorf(
			"The character '%s' is reserved for snapshots.",
			shared.SnapshotDelimiter)
	}

	if !shared.ValidHostname(name) {
		return fmt.Errorf("Container name isn't a valid hostname.")
	}

	return nil
}

func containerValidConfigKey(d *Daemon, key string, value string) error {
	f, err := shared.ConfigKeyChecker(key)
	if err != nil {
		return err
	}
	if err = f(value); err != nil {
		return err
	}
	if key == "raw.mercury" {
		return mercuryValidConfig(value)
	}
	if key == "security.syscalls.blacklist_compat" {
		for _, arch := range d.architectures {
			if arch == osarch.ARCH_64BIT_INTEL_X86 ||
				arch == osarch.ARCH_64BIT_ARMV8_LITTLE_ENDIAN ||
				arch == osarch.ARCH_64BIT_POWERPC_BIG_ENDIAN {
				return nil
			}
		}
		return fmt.Errorf("security.syscalls.blacklist_compat isn't supported on this architecture")
	}
	return nil
}

func containerValidDeviceConfigKey(t, k string) bool {
	if k == "type" {
		return true
	}

	switch t {
	case "unix-char", "unix-block":
		switch k {
		case "gid":
			return true
		case "major":
			return true
		case "minor":
			return true
		case "mode":
			return true
		case "source":
			return true
		case "path":
			return true
		case "uid":
			return true
		default:
			return false
		}
	case "nic":
		switch k {
		case "limits.max":
			return true
		case "limits.ingress":
			return true
		case "limits.egress":
			return true
		case "host_name":
			return true
		case "hwaddr":
			return true
		case "mtu":
			return true
		case "name":
			return true
		case "nictype":
			return true
		case "parent":
			return true
		case "vlan":
			return true
		case "ipv4.address":
			return true
		case "ipv6.address":
			return true
		case "security.mac_filtering":
			return true
		default:
			return false
		}
	case "disk":
		switch k {
		case "limits.max":
			return true
		case "limits.read":
			return true
		case "limits.write":
			return true
		case "optional":
			return true
		case "path":
			return true
		case "readonly":
			return true
		case "size":
			return true
		case "source":
			return true
		case "recursive":
			return true
		case "pool":
			return true
		default:
			return false
		}
	case "usb":
		switch k {
		case "vendorid":
			return true
		case "productid":
			return true
		case "mode":
			return true
		case "gid":
			return true
		case "uid":
			return true
		case "required":
			return true
		default:
			return false
		}
	case "gpu":
		switch k {
		case "vendorid":
			return true
		case "productid":
			return true
		case "id":
			return true
		case "pci":
			return true
		case "mode":
			return true
		case "gid":
			return true
		case "uid":
			return true
		default:
			return false
		}
	case "none":
		return false
	default:
		return false
	}
}

func containerValidConfig(d *Daemon, config map[string]string, profile bool, expanded bool) error {
	if config == nil {
		return nil
	}

	for k, v := range config {
		if profile && strings.HasPrefix(k, "volatile.") {
			return fmt.Errorf("Volatile keys can only be set on containers.")
		}

		if profile && strings.HasPrefix(k, "image.") {
			return fmt.Errorf("Image keys can only be set on containers.")
		}

		err := containerValidConfigKey(d, k, v)
		if err != nil {
			return err
		}
	}

	_, rawSeccomp := config["raw.seccomp"]
	_, whitelist := config["security.syscalls.whitelist"]
	_, blacklist := config["security.syscalls.blacklist"]
	blacklistDefault := shared.IsTrue(config["security.syscalls.blacklist_default"])
	blacklistCompat := shared.IsTrue(config["security.syscalls.blacklist_compat"])

	if rawSeccomp && (whitelist || blacklist || blacklistDefault || blacklistCompat) {
		return fmt.Errorf("raw.seccomp is mutually exclusive with security.syscalls*")
	}

	if whitelist && (blacklist || blacklistDefault || blacklistCompat) {
		return fmt.Errorf("security.syscalls.whitelist is mutually exclusive with security.syscalls.blacklist*")
	}

	if expanded && (config["security.privileged"] == "" || !shared.IsTrue(config["security.privileged"])) && d.IdmapSet == nil {
		return fmt.Errorf("APOLLO doesn't have a uid/gid allocation. In this mode, only privileged containers are supported.")
	}

	return nil
}

func isRootDiskDevice(device types.Device) bool {
	if device["type"] == "disk" && device["path"] == "/" && device["source"] == "" {
		return true
	}

	return false
}

func containerGetRootDiskDevice(devices types.Devices) (string, types.Device, error) {
	var devName string
	var dev types.Device

	for n, d := range devices {
		if isRootDiskDevice(d) {
			if devName != "" {
				return "", types.Device{}, fmt.Errorf("More than one root device found.")
			}

			devName = n
			dev = d
		}
	}

	if devName != "" {
		return devName, dev, nil
	}

	return "", types.Device{}, fmt.Errorf("No root device could be found.")
}

func containerValidDevices(d *Daemon, devices types.Devices, profile bool, expanded bool) error {
	// Empty device list
	if devices == nil {
		return nil
	}

	var diskDevicePaths []string
	// Check each device individually
	for name, m := range devices {
		if m["type"] == "" {
			return fmt.Errorf("Missing device type for device '%s'", name)
		}

		if !shared.StringInSlice(m["type"], []string{"none", "nic", "disk", "unix-char", "unix-block", "usb", "gpu"}) {
			return fmt.Errorf("Invalid device type for device '%s'", name)
		}

		for k := range m {
			if !containerValidDeviceConfigKey(m["type"], k) {
				return fmt.Errorf("Invalid device configuration key for %s: %s", m["type"], k)
			}
		}

		if m["type"] == "nic" {
			if m["nictype"] == "" {
				return fmt.Errorf("Missing nic type")
			}

			if !shared.StringInSlice(m["nictype"], []string{"bridged", "physical", "p2p", "macvlan"}) {
				return fmt.Errorf("Bad nic type: %s", m["nictype"])
			}

			if shared.StringInSlice(m["nictype"], []string{"bridged", "physical", "macvlan"}) && m["parent"] == "" {
				return fmt.Errorf("Missing parent for %s type nic.", m["nictype"])
			}
		} else if m["type"] == "disk" {
			if !expanded && !shared.StringInSlice(m["path"], diskDevicePaths) {
				diskDevicePaths = append(diskDevicePaths, m["path"])
			} else if !expanded {
				return fmt.Errorf("More than one disk device uses the same path: %s.", m["path"])
			}

			if m["path"] == "" {
				return fmt.Errorf("Disk entry is missing the required \"path\" property.")
			}

			if m["source"] == "" && m["path"] != "/" {
				return fmt.Errorf("Disk entry is missing the required \"source\" property.")
			}

			if m["path"] == "/" && m["source"] != "" {
				return fmt.Errorf("Root disk entry may not have a \"source\" property set.")
			}

			if m["size"] != "" && m["path"] != "/" {
				return fmt.Errorf("Only the root disk may have a size quota.")
			}

			if (m["path"] == "/" || !shared.IsDir(m["source"])) && m["recursive"] != "" {
				return fmt.Errorf("The recursive option is only supported for additional bind-mounted paths.")
			}

			if m["pool"] != "" {
				if filepath.IsAbs(m["source"]) {
					return fmt.Errorf("Storage volumes cannot be specified as absolute paths.")
				}

				_, err := db.StoragePoolGetID(d.db, m["pool"])
				if err != nil {
					return fmt.Errorf("The \"%s\" storage pool doesn't exist.", m["pool"])
				}
			}

		} else if shared.StringInSlice(m["type"], []string{"unix-char", "unix-block"}) {
			if m["source"] == "" && m["path"] == "" {
				return fmt.Errorf("Unix device entry is missing the required \"source\" or \"path\" property.")
			}

			if m["major"] == "" || m["minor"] == "" {
				srcPath, exist := m["source"]
				if !exist {
					srcPath = m["path"]
				}
				if !shared.PathExists(srcPath) {
					return fmt.Errorf("The device path doesn't exist on the host and major/minor wasn't specified.")
				}

				dType, _, _, err := deviceGetAttributes(srcPath)
				if err != nil {
					return err
				}

				if m["type"] == "unix-char" && dType != "c" {
					return fmt.Errorf("Path specified for unix-char device is a block device.")
				}

				if m["type"] == "unix-block" && dType != "b" {
					return fmt.Errorf("Path specified for unix-block device is a character device.")
				}
			}
		} else if m["type"] == "usb" {
			if m["vendorid"] == "" {
				return fmt.Errorf("Missing vendorid for USB device.")
			}
		} else if m["type"] == "gpu" {
			// Probably no checks needed, since we allow users to
			// pass in all GPUs.
		} else if m["type"] == "none" {
			continue
		} else {
			return fmt.Errorf("Invalid device type: %s", m["type"])
		}
	}

	// Checks on the expanded config
	if expanded {
		_, _, err := containerGetRootDiskDevice(devices)
		if err != nil {
			return err
		}
	}

	return nil
}

// The container interface
type container interface {
	// Container actions
	Freeze() error
	Shutdown(timeout time.Duration) error
	Start(stateful bool) error
	Stop(stateful bool) error
	Unfreeze() error

	// Snapshots & migration
	Restore(sourceContainer container, stateful bool) error
	/* actionScript here is a script called action.sh in the stateDir, to
	 * be passed to CRIU as --action-script
	 */
	Migrate(cmd uint, stateDir string, function string, stop bool, actionScript bool) error
	Snapshots() ([]container, error)

	// Config handling
	Rename(newName string) error
	Update(newConfig db.ContainerArgs, userRequested bool) error

	Delete() error
	Export(w io.Writer, properties map[string]string) error

	// Live configuration
	CGroupGet(key string) (string, error)
	CGroupSet(key string, value string) error
	ConfigKeySet(key string, value string) error

	// File handling
	FileExists(path string) error
	FilePull(srcpath string, dstpath string) (int64, int64, os.FileMode, string, []string, error)
	FilePush(type_ string, srcpath string, dstpath string, uid int64, gid int64, mode int, write string) error
	FileRemove(path string) error

	/* Command execution:
		 * 1. passing in false for wait
		 *    - equivalent to calling cmd.Run()
		 * 2. passing in true for wait
	         *    - start the command and return its PID in the first return
	         *      argument and the PID of the attached process in the second
	         *      argument. It's the callers responsibility to wait on the
	         *      command. (Note. The returned PID of the attached process can not
	         *      be waited upon since it's a child of the apollo forkexec command
	         *      (the PID returned in the first return argument). It can however
	         *      be used to e.g. forward signals.)
	*/
	Exec(command []string, env map[string]string, stdin *os.File, stdout *os.File, stderr *os.File, wait bool) (*exec.Cmd, int, int, error)

	// Status
	Render() (interface{}, interface{}, error)
	RenderState() (*api.ContainerState, error)
	IsPrivileged() bool
	IsRunning() bool
	IsFrozen() bool
	IsEphemeral() bool
	IsSnapshot() bool
	IsStateful() bool
	IsNesting() bool

	// Hooks
	OnStart() error
	OnStop(target string) error

	// Properties
	Id() int
	Name() string
	Description() string
	Architecture() int
	CreationDate() time.Time
	LastUsedDate() time.Time
	ExpandedConfig() map[string]string
	ExpandedDevices() types.Devices
	LocalConfig() map[string]string
	LocalDevices() types.Devices
	Profiles() []string
	InitPID() int
	State() string

	// Paths
	Path() string
	RootfsPath() string
	TemplatesPath() string
	StatePath() string
	LogFilePath() string
	LogPath() string

	StoragePool() (string, error)

	// FIXME: Those should be internal functions
	// Needed for migration for now.
	StorageStart() (bool, error)
	StorageStop() (bool, error)
	Storage() storage
	IdmapSet() (*shared.IdmapSet, error)
	LastIdmapSet() (*shared.IdmapSet, error)
	TemplateApply(trigger string) error
	Daemon() *Daemon
}

// Loader functions
func containerCreateAsEmpty(d *Daemon, args db.ContainerArgs) (container, error) {
	// Create the container
	c, err := containerCreateInternal(d, args)
	if err != nil {
		return nil, err
	}

	// Now create the empty storage
	if err := c.Storage().ContainerCreate(c); err != nil {
		c.Delete()
		return nil, err
	}

	// Apply any post-storage configuration
	err = containerConfigureInternal(c)
	if err != nil {
		c.Delete()
		return nil, err
	}

	return c, nil
}

func containerCreateEmptySnapshot(d *Daemon, args db.ContainerArgs) (container, error) {
	// Create the snapshot
	c, err := containerCreateInternal(d, args)
	if err != nil {
		return nil, err
	}

	// Now create the empty snapshot
	if err := c.Storage().ContainerSnapshotCreateEmpty(c); err != nil {
		c.Delete()
		return nil, err
	}

	return c, nil
}

func containerCreateFromImage(d *Daemon, args db.ContainerArgs, hash string) (container, error) {
	// Get the image properties
	_, img, err := db.ImageGet(d.db, hash, false, false)
	if err != nil {
		return nil, err
	}

	// Set the "image.*" keys
	if img.Properties != nil {
		for k, v := range img.Properties {
			args.Config[fmt.Sprintf("image.%s", k)] = v
		}
	}

	// Set the BaseImage field (regardless of previous value)
	args.BaseImage = hash

	// Create the container
	c, err := containerCreateInternal(d, args)
	if err != nil {
		return nil, err
	}

	if err := db.ImageLastAccessUpdate(d.db, hash, time.Now().UTC()); err != nil {
		return nil, fmt.Errorf("Error updating image last use date: %s", err)
	}

	// Now create the storage from an image
	if err := c.Storage().ContainerCreateFromImage(c, hash); err != nil {
		c.Delete()
		return nil, err
	}

	// Apply any post-storage configuration
	err = containerConfigureInternal(c)
	if err != nil {
		c.Delete()
		return nil, err
	}

	return c, nil
}

func containerCreateAsCopy(d *Daemon, args db.ContainerArgs, sourceContainer container, containerOnly bool) (container, error) {
	// Create the container.
	ct, err := containerCreateInternal(d, args)
	if err != nil {
		return nil, err
	}

	csList := []*container{}
	if !containerOnly {
		snapshots, err := sourceContainer.Snapshots()
		if err != nil {
			return nil, err
		}

		csList = make([]*container, len(snapshots))
		for i, snap := range snapshots {
			fields := strings.SplitN(snap.Name(), shared.SnapshotDelimiter, 2)
			newSnapName := fmt.Sprintf("%s/%s", ct.Name(), fields[1])
			csArgs := db.ContainerArgs{
				Architecture: snap.Architecture(),
				Config:       snap.LocalConfig(),
				Ctype:        db.CTypeSnapshot,
				Devices:      snap.LocalDevices(),
				Ephemeral:    snap.IsEphemeral(),
				Name:         newSnapName,
				Profiles:     snap.Profiles(),
			}

			// Create the snapshots.
			cs, err := containerCreateInternal(d, csArgs)
			if err != nil {
				return nil, err
			}

			csList[i] = &cs
		}
	}

	// Now clone the storage.
	if err := ct.Storage().ContainerCopy(ct, sourceContainer, containerOnly); err != nil {
		ct.Delete()
		return nil, err
	}

	// Apply any post-storage configuration.
	err = containerConfigureInternal(ct)
	if err != nil {
		ct.Delete()
		return nil, err
	}

	if !containerOnly {
		for _, cs := range csList {
			// Apply any post-storage configuration.
			err = containerConfigureInternal(*cs)
			if err != nil {
				(*cs).Delete()
				return nil, err
			}
		}
	}

	return ct, nil
}

func containerCreateAsSnapshot(d *Daemon, args db.ContainerArgs, sourceContainer container) (container, error) {
	// Deal with state
	if args.Stateful {
		if !sourceContainer.IsRunning() {
			return nil, fmt.Errorf("Unable to create a stateful snapshot. The container isn't running.")
		}

		_, err := exec.LookPath("criu")
		if err != nil {
			return nil, fmt.Errorf("Unable to create a stateful snapshot. CRIU isn't installed.")
		}

		stateDir := sourceContainer.StatePath()
		err = os.MkdirAll(stateDir, 0700)
		if err != nil {
			return nil, err
		}

		/* TODO: ideally we would freeze here and unfreeze below after
		 * we've copied the filesystem, to make sure there are no
		 * changes by the container while snapshotting. Unfortunately
		 * there is abug in CRIU where it doesn't leave the container
		 * in the same state it found it w.r.t. freezing, i.e. CRIU
		 * freezes too, and then /always/ thaws, even if the container
		 * was frozen. Until that's fixed, all calls to Unfreeze()
		 * after snapshotting will fail.
		 */

		err = sourceContainer.Migrate(mercury.MIGRATE_DUMP, stateDir, "snapshot", false, false)
		if err != nil {
			os.RemoveAll(sourceContainer.StatePath())
			return nil, err
		}
	}

	// Create the snapshot
	c, err := containerCreateInternal(d, args)
	if err != nil {
		return nil, err
	}

	// Clone the container
	if err := sourceContainer.Storage().ContainerSnapshotCreate(c, sourceContainer); err != nil {
		c.Delete()
		return nil, err
	}

	ourStart, err := c.StorageStart()
	if err != nil {
		return nil, err
	}
	if ourStart {
		defer c.StorageStop()
	}

	err = writeBackupFile(sourceContainer)
	if err != nil {
		c.Delete()
		return nil, err
	}

	// Once we're done, remove the state directory
	if args.Stateful {
		os.RemoveAll(sourceContainer.StatePath())
	}

	return c, nil
}

func containerCreateInternal(d *Daemon, args db.ContainerArgs) (container, error) {
	// Set default values
	if args.Profiles == nil {
		args.Profiles = []string{"default"}
	}

	if args.Config == nil {
		args.Config = map[string]string{}
	}

	if args.BaseImage != "" {
		args.Config["volatile.base_image"] = args.BaseImage
	}

	if args.Devices == nil {
		args.Devices = types.Devices{}
	}

	if args.Architecture == 0 {
		args.Architecture = d.architectures[0]
	}

	// Validate container name
	if args.Ctype == db.CTypeRegular {
		err := containerValidName(args.Name)
		if err != nil {
			return nil, err
		}
	}

	// Validate container config
	err := containerValidConfig(d, args.Config, false, false)
	if err != nil {
		return nil, err
	}

	// Validate container devices
	err = containerValidDevices(d, args.Devices, false, false)
	if err != nil {
		return nil, err
	}

	// Validate architecture
	_, err = osarch.ArchitectureName(args.Architecture)
	if err != nil {
		return nil, err
	}

	if !shared.IntInSlice(args.Architecture, d.architectures) {
		return nil, fmt.Errorf("Requested architecture isn't supported by this host")
	}

	// Validate profiles
	profiles, err := db.Profiles(d.db)
	if err != nil {
		return nil, err
	}

	for _, profile := range args.Profiles {
		if !shared.StringInSlice(profile, profiles) {
			return nil, fmt.Errorf("Requested profile '%s' doesn't exist", profile)
		}
	}

	// Create the container entry
	id, err := db.ContainerCreate(d.db, args)
	if err != nil {
		if err == db.DbErrAlreadyDefined {
			thing := "Container"
			if shared.IsSnapshot(args.Name) {
				thing = "Snapshot"
			}
			return nil, fmt.Errorf("%s '%s' already exists", thing, args.Name)
		}
		return nil, err
	}

	// Wipe any existing log for this container name
	os.RemoveAll(shared.LogPath(args.Name))

	args.Id = id

	// Read the timestamp from the database
	dbArgs, err := db.ContainerGet(d.db, args.Name)
	if err != nil {
		return nil, err
	}
	args.CreationDate = dbArgs.CreationDate
	args.LastUsedDate = dbArgs.LastUsedDate

	// Setup the container struct and finish creation (storage and idmap)
	c, err := containerMERCURYCreate(d, args)
	if err != nil {
		return nil, err
	}

	return c, nil
}

func containerConfigureInternal(c container) error {
	// Find the root device
	_, rootDiskDevice, err := containerGetRootDiskDevice(c.ExpandedDevices())
	if err != nil {
		return err
	}

	ourStart, err := c.StorageStart()
	if err != nil {
		return err
	}

	// handle quota: at this point, storage is guaranteed to be ready
	storage := c.Storage()
	if rootDiskDevice["size"] != "" {
		storageTypeName := storage.GetStorageTypeName()
		if storageTypeName == "lvm" && c.IsRunning() {
			err = c.ConfigKeySet("volatile.apply_quota", rootDiskDevice["size"])
			if err != nil {
				return err
			}
		} else {
			size, err := shared.ParseByteSizeString(rootDiskDevice["size"])
			if err != nil {
				return err
			}

			err = storage.StorageEntitySetQuota(storagePoolVolumeTypeContainer, size, c)
			if err != nil {
				return err
			}
		}
	}

	if ourStart {
		defer c.StorageStop()
	}

	err = writeBackupFile(c)
	if err != nil {
		return err
	}

	return nil
}

func containerLoadById(d *Daemon, id int) (container, error) {
	// Get the DB record
	name, err := db.ContainerName(d.db, id)
	if err != nil {
		return nil, err
	}

	return containerLoadByName(d, name)
}

func containerLoadByName(d *Daemon, name string) (container, error) {
	// Get the DB record
	args, err := db.ContainerGet(d.db, name)
	if err != nil {
		return nil, err
	}

	return containerMERCURYLoad(d, args)
}
