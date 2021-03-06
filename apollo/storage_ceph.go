package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"

	"github.com/AriseBank/apollo-controller/apollo/db"
	"github.com/AriseBank/apollo-controller/shared"
	"github.com/AriseBank/apollo-controller/shared/api"
	"github.com/AriseBank/apollo-controller/shared/logger"
)

type storageCeph struct {
	ClusterName string
	OSDPoolName string
	UserName    string
	PGNum       string
	storageShared
}

func (s *storageCeph) StorageCoreInit() error {
	s.sType = storageTypeCeph
	typeName, err := storageTypeToString(s.sType)
	if err != nil {
		return err
	}
	s.sTypeName = typeName

	msg, err := shared.RunCommand("rbd", "--version")
	if err != nil {
		return fmt.Errorf("Error getting CEPH version: %s", err)
	}
	s.sTypeVersion = strings.TrimSpace(msg)

	logger.Debugf("Initializing a CEPH driver")
	return nil
}

func (s *storageCeph) StoragePoolInit() error {
	var err error

	err = s.StorageCoreInit()
	if err != nil {
		return err
	}

	// set cluster name
	if s.pool.Config["ceph.cluster_name"] != "" {
		s.ClusterName = s.pool.Config["ceph.cluster_name"]
	} else {
		s.ClusterName = "ceph"
	}

	// set osd pool name
	if s.pool.Config["ceph.osd.pool_name"] != "" {
		s.OSDPoolName = s.pool.Config["ceph.osd.pool_name"]
	}

	// set ceph user name
	if s.pool.Config["ceph.user.name"] != "" {
		s.UserName = s.pool.Config["ceph.user.name"]
	} else {
		s.UserName = "admin"
	}

	// set default placement group number
	if s.pool.Config["ceph.osd.pg_num"] != "" {
		_, err = shared.ParseByteSizeString(s.pool.Config["ceph.osd.pg_num"])
		if err != nil {
			return err
		}
		s.PGNum = s.pool.Config["ceph.osd.pg_num"]
	} else {
		s.PGNum = "32"
	}

	return nil
}

func (s *storageCeph) StoragePoolCheck() error {
	logger.Debugf(`Checking CEPH storage pool "%s" (noop)`, s.pool.Name)
	logger.Debugf(`Checked CEPH storage pool "%s" (noop)`, s.pool.Name)
	return nil
}

func (s *storageCeph) StoragePoolCreate() error {
	logger.Infof(`Creating CEPH OSD storage pool "%s" in cluster "%s"`,
		s.pool.Name, s.ClusterName)

	revert := true

	s.pool.Config["volatile.initial_source"] = s.pool.Config["source"]

	// sanity check
	if s.pool.Config["source"] != "" &&
		s.pool.Config["ceph.osd.pool_name"] != "" &&
		s.pool.Config["source"] != s.pool.Config["ceph.osd.pool_name"] {
		msg := fmt.Sprintf(`The "source" and "ceph.osd.pool_name" ` +
			`property must not differ for CEPH OSD storage pools`)
		logger.Errorf(msg)
		return fmt.Errorf(msg)
	}

	// use an existing OSD pool
	if s.pool.Config["source"] != "" {
		s.OSDPoolName = s.pool.Config["source"]
		s.pool.Config["ceph.osd.pool_name"] = s.pool.Config["source"]
	}

	if s.pool.Config["ceph.osd.pool_name"] == "" {
		s.pool.Config["ceph.osd.pool_name"] = s.pool.Name
		s.pool.Config["source"] = s.pool.Name
		s.OSDPoolName = s.pool.Name
	}

	if !cephOSDPoolExists(s.ClusterName, s.OSDPoolName, s.UserName) {
		logger.Debugf(`CEPH OSD storage pool "%s" does not exist`, s.OSDPoolName)

		// create new osd pool
		msg, err := shared.TryRunCommand("ceph", "--name",
			fmt.Sprintf("client.%s", s.UserName), "--cluster",
			s.ClusterName, "osd", "pool", "create", s.OSDPoolName,
			s.PGNum)
		if err != nil {
			logger.Errorf(`Failed to create CEPH osd storage pool `+
				`"%s" in cluster "%s": %s`, s.OSDPoolName,
				s.ClusterName, msg)
			return err
		}
		logger.Debugf(`Created CEPH osd storage pool "%s" in cluster `+
			`"%s"`, s.OSDPoolName, s.ClusterName)

		defer func() {
			if !revert {
				return
			}

			err := cephOSDPoolDestroy(s.ClusterName, s.OSDPoolName,
				s.UserName)
			if err != nil {
				logger.Warnf(`Failed to delete ceph storage `+
					`pool "%s" in cluster "%s": %s`,
					s.OSDPoolName, s.ClusterName, err)
			}
		}()

	} else {
		logger.Debugf(`CEPH OSD storage pool "%s" does exist`, s.OSDPoolName)

		// use existing osd pool
		msg, err := shared.RunCommand("ceph", "--name",
			fmt.Sprintf("client.%s", s.UserName),
			"--cluster", s.ClusterName, "osd", "pool", "get",
			s.OSDPoolName, "pg_num")
		if err != nil {
			logger.Errorf(`Failed to retrieve number of placement `+
				`groups for CEPH osd storage pool "%s" in `+
				`cluster "%s": %s`, s.OSDPoolName,
				s.ClusterName, msg)
			return err
		}
		logger.Debugf(`Retrieved number of placement groups or CEPH `+
			`osd storage pool "%s" in cluster "%s"`, s.OSDPoolName,
			s.ClusterName)

		idx := strings.Index(msg, "pg_num:")
		if idx == -1 {
			logger.Errorf(`Failed to parse number of placement `+
				`groups for CEPH osd storage pool "%s" in `+
				`cluster "%s": %s`, s.OSDPoolName,
				s.ClusterName, msg)
		}

		msg = msg[(idx + len("pg_num:")):]
		msg = strings.TrimSpace(msg)
		// It is ok to update the pool configuration since storage pool
		// creation via API is implemented such that the storage pool is
		// checked for a changed config after this function returns and
		// if so the db for it is updated.
		s.pool.Config["ceph.osd.pg_num"] = msg
	}

	if s.pool.Config["source"] == "" {
		s.pool.Config["source"] = s.OSDPoolName
	}

	// set immutable ceph.cluster_name property
	if s.pool.Config["ceph.cluster_name"] == "" {
		s.pool.Config["ceph.cluster_name"] = "ceph"
	}

	// set immutable ceph.osd.pool_name property
	if s.pool.Config["ceph.osd.pool_name"] == "" {
		s.pool.Config["ceph.osd.pool_name"] = s.pool.Name
	}

	if s.pool.Config["ceph.osd.pg_num"] == "" {
		s.pool.Config["ceph.osd.pg_num"] = "32"
	}

	// Create the mountpoint for the storage pool.
	poolMntPoint := getStoragePoolMountPoint(s.pool.Name)
	err := os.MkdirAll(poolMntPoint, 0711)
	if err != nil {
		logger.Errorf(`Failed to create mountpoint "%s" for ceph `+
			`storage pool "%s" in cluster "%s": %s`, poolMntPoint,
			s.OSDPoolName, s.ClusterName, err)
		return err
	}
	logger.Debugf(`Created mountpoint "%s" for ceph storage pool "%s" in `+
		`cluster "%s"`, poolMntPoint, s.OSDPoolName, s.ClusterName)

	defer func() {
		if !revert {
			return
		}

		err := os.Remove(poolMntPoint)
		if err != nil {
			logger.Errorf(`Failed to delete mountpoint "%s" for `+
				`ceph storage pool "%s" in cluster "%s": %s`,
				poolMntPoint, s.OSDPoolName, s.ClusterName, err)
		}
	}()

	ok := cephRBDVolumeExists(s.ClusterName, s.OSDPoolName, s.pool.Name,
		"apollo", s.UserName)
	s.pool.Config["volatile.pool.pristine"] = "false"
	if !ok {
		s.pool.Config["volatile.pool.pristine"] = "true"
		// Create dummy storage volume. Other APOLLO instances will use
		// this to detect whether this osd pool is already in use by
		// another APOLLO instance.
		err = cephRBDVolumeCreate(s.ClusterName, s.OSDPoolName,
			s.pool.Name, "apollo", "0", s.UserName)
		if err != nil {
			logger.Errorf(`Failed to create RBD storage volume `+
				`"%s" on storage pool "%s": %s`, s.pool.Name,
				s.pool.Name, err)
			return err
		}
		logger.Debugf(`Created RBD storage volume "%s" on storage `+
			`pool "%s"`, s.pool.Name, s.pool.Name)
	}

	logger.Infof(`Created CEPH OSD storage pool "%s" in cluster "%s"`,
		s.pool.Name, s.ClusterName)

	revert = false

	return nil
}

func (s *storageCeph) StoragePoolDelete() error {
	logger.Infof(`Deleting CEPH OSD storage pool "%s" in cluster "%s"`,
		s.pool.Name, s.ClusterName)

	// test if pool exists
	if !cephOSDPoolExists(s.ClusterName, s.OSDPoolName, s.UserName) {
		msg := fmt.Sprintf(`CEPH osd storage pool "%s" does not exist `+
			`in cluster "%s"`, s.OSDPoolName, s.ClusterName)
		logger.Errorf(msg)
		return fmt.Errorf(msg)
	}

	// Check whether we own the pool and only remove in this case.
	if s.pool.Config["volatile.pool.pristine"] != "" &&
		shared.IsTrue(s.pool.Config["volatile.pool.pristine"]) {
		logger.Debugf(`Detected that this APOLLO instance is the owner `+
			`of the CEPH osd storage pool "%s" in cluster "%s"`,
			s.OSDPoolName, s.ClusterName)

		// Delete the osd pool.
		err := cephOSDPoolDestroy(s.ClusterName, s.OSDPoolName,
			s.UserName)
		if err != nil {
			logger.Errorf(`Failed to delete CEPH OSD storage pool `+
				`"%s" in cluster "%s": %s`, s.pool.Name,
				s.ClusterName, err)
			return err
		}
		logger.Debugf(`Deleted CEPH OSD storage pool "%s" in cluster "%s"`,
			s.pool.Name, s.ClusterName)
	}

	// Delete the mountpoint for the storage pool.
	poolMntPoint := getStoragePoolMountPoint(s.pool.Name)
	err := os.RemoveAll(poolMntPoint)
	if err != nil {
		logger.Errorf(`Failed to delete mountpoint "%s" for CEPH osd `+
			`storage pool "%s" in cluster "%s": %s`, poolMntPoint,
			s.OSDPoolName, s.ClusterName, err)
		return err
	}
	logger.Debugf(`Deleted mountpoint "%s" for CEPH osd storage pool "%s" `+
		`in cluster "%s"`, poolMntPoint, s.OSDPoolName, s.ClusterName)

	logger.Infof(`Deleted CEPH OSD storage pool "%s" in cluster "%s"`,
		s.pool.Name, s.ClusterName)
	return nil
}

func (s *storageCeph) StoragePoolMount() (bool, error) {
	// Yay, osd pools are not mounted.
	return true, nil
}

func (s *storageCeph) StoragePoolUmount() (bool, error) {
	// Yay, osd pools are not mounted.
	return true, nil
}

func (s *storageCeph) GetStoragePoolWritable() api.StoragePoolPut {
	return s.pool.StoragePoolPut
}

func (s *storageCeph) GetStoragePoolVolumeWritable() api.StorageVolumePut {
	return s.volume.Writable()
}

func (s *storageCeph) SetStoragePoolWritable(writable *api.StoragePoolPut) {
	s.pool.StoragePoolPut = *writable
}

func (s *storageCeph) SetStoragePoolVolumeWritable(writable *api.StorageVolumePut) {
	s.volume.StorageVolumePut = *writable
}

func (s *storageCeph) GetContainerPoolInfo() (int64, string) {
	return s.poolID, s.pool.Name
}

func (s *storageCeph) StoragePoolVolumeCreate() error {
	logger.Debugf(`Creating RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	revert := true

	// get size
	RBDSize, err := s.getRBDSize()
	if err != nil {
		logger.Errorf(`Failed to retrieve size of RBD storage volume `+
			`"%s" on storage pool "%s": %s`, s.volume.Name,
			s.pool.Name, err)
		return err
	}
	logger.Debugf(`Retrieved size "%s" of RBD storage volume "%s" on `+
		`storage pool "%s"`, RBDSize, s.volume.Name, s.pool.Name)

	// create volume
	err = cephRBDVolumeCreate(s.ClusterName, s.OSDPoolName, s.volume.Name,
		storagePoolVolumeTypeNameCustom, RBDSize, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to create RBD storage volume "%s" on `+
			`storage pool "%s": %s`, s.volume.Name, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Created RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName,
			s.volume.Name, storagePoolVolumeTypeNameCustom, s.UserName)
		if err != nil {
			logger.Warnf(`Failed to delete RBD storage volume `+
				`"%s" on storage pool "%s": %s`, s.volume.Name,
				s.pool.Name, err)
		}
	}()

	RBDDevPath, err := cephRBDVolumeMap(s.ClusterName, s.OSDPoolName,
		s.volume.Name, storagePoolVolumeTypeNameCustom, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to map RBD storage volume for "%s" on `+
			`storage pool "%s": %s`, s.volume.Name, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Mapped RBD storage volume for "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
			s.volume.Name, storagePoolVolumeTypeNameCustom,
			s.UserName, true)
		if err != nil {
			logger.Warnf(`Failed to unmap RBD storage volume `+
				`"%s" on storage pool "%s": %s`, s.volume.Name,
				s.pool.Name, err)
		}
	}()

	// get filesystem
	RBDFilesystem := s.getRBDFilesystem()
	logger.Debugf(`Retrieved filesystem type "%s" of RBD storage volume `+
		`"%s" on storage pool "%s"`, RBDFilesystem, s.volume.Name,
		s.pool.Name)

	msg, err := makeFSType(RBDDevPath, RBDFilesystem)
	if err != nil {
		logger.Errorf(`Failed to create filesystem type "%s" on `+
			`device path "%s" for RBD storage volume "%s" on `+
			`storage pool "%s": %s`, RBDFilesystem, RBDDevPath,
			s.volume.Name, s.pool.Name, msg)
		return err
	}
	logger.Debugf(`Created filesystem type "%s" on device path "%s" for `+
		`RBD storage volume "%s" on storage pool "%s"`, RBDFilesystem,
		RBDDevPath, s.volume.Name, s.pool.Name)

	volumeMntPoint := getStoragePoolVolumeMountPoint(s.pool.Name, s.volume.Name)
	err = os.MkdirAll(volumeMntPoint, 0711)
	if err != nil {
		logger.Errorf(`Failed to create mountpoint "%s" for RBD `+
			`storage volume "%s" on storage pool "%s": %s"`,
			volumeMntPoint, s.volume.Name, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Created mountpoint "%s" for RBD storage volume "%s" `+
		`on storage pool "%s"`, volumeMntPoint, s.volume.Name,
		s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := os.Remove(volumeMntPoint)
		if err != nil {
			logger.Warnf(`Failed to delete mountpoint "%s" for RBD `+
				`storage volume "%s" on storage pool "%s": %s"`,
				volumeMntPoint, s.volume.Name, s.pool.Name, err)
		}
	}()

	logger.Debugf(`Created RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	revert = false

	return nil
}

func (s *storageCeph) StoragePoolVolumeDelete() error {
	logger.Debugf(`Deleting RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	volumeMntPoint := getStoragePoolVolumeMountPoint(s.pool.Name, s.volume.Name)
	if shared.IsMountPoint(volumeMntPoint) {
		err := tryUnmount(volumeMntPoint, syscall.MNT_DETACH)
		if err != nil {
			logger.Errorf(`Failed to unmount RBD storage volume `+
				`"%s" on storage pool "%s": %s`, s.volume.Name,
				s.pool.Name, err)
		}
		logger.Debugf(`Unmounted RBD storage volume "%s" on storage `+
			`pool "%s"`, s.volume.Name, s.pool.Name)
	}

	// unmap
	err := cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName, s.volume.Name,
		storagePoolVolumeTypeNameCustom, s.UserName, true)
	if err != nil {
		logger.Errorf(`Failed to unmap RBD storage volume "%s" on `+
			`storage pool "%s": %s`, s.volume.Name, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Unmapped RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	// delete
	err = cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName, s.volume.Name,
		storagePoolVolumeTypeNameCustom, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to delete RBD storage volume "%s" on `+
			`storage pool "%s": %s`, s.volume.Name, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Deleted RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	err = db.StoragePoolVolumeDelete(
		s.d.db,
		s.volume.Name,
		storagePoolVolumeTypeCustom,
		s.poolID)
	if err != nil {
		logger.Errorf(`Failed to delete database entry for RBD `+
			`storage volume "%s" on storage pool "%s"`,
			s.volume.Name, s.pool.Name)
	}
	logger.Debugf(`Deleted database entry for RBD storage volume "%s" on `+
		`storage pool "%s"`, s.volume.Name, s.pool.Name)

	err = os.Remove(volumeMntPoint)
	if err != nil {
		logger.Errorf(`Failed to delete mountpoint "%s" for RBD `+
			`storage volume "%s" on storage pool "%s": %s"`,
			volumeMntPoint, s.volume.Name, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Deleted mountpoint "%s" for RBD storage volume "%s" `+
		`on storage pool "%s"`, volumeMntPoint, s.volume.Name,
		s.pool.Name)

	logger.Debugf(`Deleted RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)
	return nil
}

func (s *storageCeph) StoragePoolVolumeMount() (bool, error) {
	logger.Debugf(`Mounting RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	RBDFilesystem := s.getRBDFilesystem()
	volumeMntPoint := getStoragePoolVolumeMountPoint(s.pool.Name, s.volume.Name)

	customMountLockID := getCustomMountLockID(s.pool.Name, s.volume.Name)
	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[customMountLockID]; ok {
		apolloStorageMapLock.Unlock()
		if _, ok := <-waitChannel; ok {
			logger.Warnf(`Received value over semaphore. This ` +
				`should not have happened`)
		}
		// Give the benefit of the doubt and assume that the other
		// thread actually succeeded in mounting the storage volume.
		logger.Debugf(`RBD storage volume "%s" on storage pool "%s" `+
			`appears to be already mounted`, s.volume.Name,
			s.pool.Name)
		return false, nil
	}

	apolloStorageOngoingOperationMap[customMountLockID] = make(chan bool)
	apolloStorageMapLock.Unlock()

	var ret int
	var customerr error
	ourMount := false
	RBDDevPath := ""
	if !shared.IsMountPoint(volumeMntPoint) {
		RBDDevPath, ret = getRBDMappedDevPath(s.ClusterName, s.OSDPoolName,
			storagePoolVolumeTypeNameCustom, s.volume.Name, true,
			s.UserName)
		mountFlags, mountOptions := apolloResolveMountoptions(s.getRBDMountOptions())
		customerr = tryMount(
			RBDDevPath,
			volumeMntPoint,
			RBDFilesystem,
			mountFlags,
			mountOptions)
		ourMount = true
	}

	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[customMountLockID]; ok {
		close(waitChannel)
		delete(apolloStorageOngoingOperationMap, customMountLockID)
	}
	apolloStorageMapLock.Unlock()

	if customerr != nil || ret < 0 {
		logger.Errorf(`Failed to mount RBD storage volume "%s" on `+
			`storage pool "%s": %s`, s.volume.Name, s.pool.Name,
			customerr)
		return false, customerr
	}

	logger.Debugf(`Mounted RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)
	return ourMount, nil
}

func (s *storageCeph) StoragePoolVolumeUmount() (bool, error) {
	logger.Debugf(`Unmounting RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)

	volumeMntPoint := getStoragePoolVolumeMountPoint(s.pool.Name, s.volume.Name)

	customMountLockID := getCustomUmountLockID(s.pool.Name, s.volume.Name)
	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[customMountLockID]; ok {
		apolloStorageMapLock.Unlock()
		if _, ok := <-waitChannel; ok {
			logger.Warnf(`Received value over semaphore. This ` +
				`should not have happened`)
		}
		// Give the benefit of the doubt and assume that the other
		// thread actually succeeded in unmounting the storage volume.
		logger.Debugf(`RBD storage volume "%s" on storage pool "%s" `+
			`appears to be already unmounted`, s.volume.Name,
			s.pool.Name)
		return false, nil
	}

	apolloStorageOngoingOperationMap[customMountLockID] = make(chan bool)
	apolloStorageMapLock.Unlock()

	var customerr error
	ourUmount := false
	if shared.IsMountPoint(volumeMntPoint) {
		customerr = tryUnmount(volumeMntPoint, syscall.MNT_DETACH)
		ourUmount = true
		logger.Debugf(`Path "%s" is a mountpoint for RBD storage `+
			`volume "%s" on storage pool "%s"`, volumeMntPoint,
			s.volume.Name, s.pool.Name)
	}

	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[customMountLockID]; ok {
		close(waitChannel)
		delete(apolloStorageOngoingOperationMap, customMountLockID)
	}
	apolloStorageMapLock.Unlock()

	if customerr != nil {
		logger.Errorf(`Failed to unmount RBD storage volume "%s" on `+
			`storage pool "%s": %s`, s.volume.Name, s.pool.Name,
			customerr)
		return false, customerr
	}

	logger.Debugf(`Unmounted RBD storage volume "%s" on storage pool "%s"`,
		s.volume.Name, s.pool.Name)
	return ourUmount, nil
}

func (s *storageCeph) StoragePoolVolumeUpdate(writable *api.StorageVolumePut, changedConfig []string) error {
	return fmt.Errorf("RBD storage volume properties cannot be changed")
}

func (s *storageCeph) StoragePoolUpdate(writable *api.StoragePoolPut, changedConfig []string) error {
	return fmt.Errorf("ODS storage pool properties cannot be changed")
}

func (s *storageCeph) ContainerStorageReady(name string) bool {
	logger.Debugf(`Checking if RBD storage volume for container "%s" `+
		`on storage pool "%s" is ready`, name, s.pool.Name)

	ok := cephRBDVolumeExists(s.ClusterName, s.OSDPoolName, name,
		storagePoolVolumeTypeNameContainer, s.UserName)
	if !ok {
		logger.Debugf(`RBD storage volume for container "%s" `+
			`on storage pool "%s" does not exist`, name, s.pool.Name)
		return false
	}

	logger.Debugf(`RBD storage volume for container "%s" `+
		`on storage pool "%s" is ready`, name, s.pool.Name)
	return true
}

func (s *storageCeph) ContainerCreate(container container) error {
	containerName := container.Name()

	logger.Debugf(`Creating RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	revert := true

	// get size
	RBDSize, err := s.getRBDSize()
	if err != nil {
		logger.Errorf(`Failed to retrieve size of RBD storage volume `+
			`for container "%s" on storage pool "%s": %s`, containerName,
			s.pool.Name, err)
		return err
	}
	logger.Debugf(`Retrieved size "%s" of RBD storage volume for `+
		`container "%s" on storage pool "%s"`, RBDSize, containerName,
		s.pool.Name)

	// create volume
	err = cephRBDVolumeCreate(s.ClusterName, s.OSDPoolName, containerName,
		storagePoolVolumeTypeNameContainer, RBDSize, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to create RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`,
			containerName, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Created RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName,
			containerName, storagePoolVolumeTypeNameContainer,
			s.UserName)
		if err != nil {
			logger.Warnf(`Failed to delete RBD storage volume for `+
				`container "%s" on storage pool "%s": %s`,
				containerName, s.pool.Name, err)
		}
	}()

	RBDDevPath, err := cephRBDVolumeMap(s.ClusterName, s.OSDPoolName,
		containerName, storagePoolVolumeTypeNameContainer, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to map RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`,
			containerName, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Mapped RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
			containerName, storagePoolVolumeTypeNameContainer,
			s.UserName, true)
		if err != nil {
			logger.Warnf(`Failed to unmap RBD storage volume `+
				`for container "%s" on storage pool "%s": %s`,
				containerName, s.pool.Name, err)
		}
	}()

	// get filesystem
	RBDFilesystem := s.getRBDFilesystem()
	logger.Debugf(`Retrieved filesystem type "%s" of RBD storage volume `+
		`for container "%s" on storage pool "%s"`, RBDFilesystem,
		containerName, s.pool.Name)

	msg, err := makeFSType(RBDDevPath, RBDFilesystem)
	if err != nil {
		logger.Errorf(`Failed to create filesystem type "%s" on `+
			`device path "%s" for RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`,
			RBDFilesystem, RBDDevPath, containerName, s.pool.Name,
			msg)
		return err
	}
	logger.Debugf(`Created filesystem type "%s" on device path "%s" for `+
		`RBD storage volume for container "%s" on storage pool "%s"`,
		RBDFilesystem, RBDDevPath, containerName, s.pool.Name)

	containerMntPoint := getContainerMountPoint(s.pool.Name, containerName)
	err = createContainerMountpoint(
		containerMntPoint,
		container.Path(),
		container.IsPrivileged())
	if err != nil {
		logger.Errorf(`Failed to create mountpoint "%s" for RBD `+
			`storage volume for container "%s" on storage pool `+
			`"%s": %s"`, containerMntPoint, containerName,
			s.pool.Name, err)
		return err
	}
	logger.Debugf(`Created mountpoint "%s" for RBD storage volume for `+
		`container "%s" on storage pool "%s""`, containerMntPoint,
		containerName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := os.Remove(containerMntPoint)
		if err != nil {
			logger.Warnf(`Failed to delete mountpoint "%s" for `+
				`RBD storage volume for container "%s" on `+
				`storage pool `+`"%s": %s"`, containerMntPoint,
				containerName, s.pool.Name, err)
		}
	}()

	err = container.TemplateApply("create")
	if err != nil {
		logger.Errorf(`Failed to apply create template for container `+
			`"%s": %s`, containerName, err)
		return err
	}
	logger.Debugf(`Applied create template for container "%s"`,
		containerName)

	logger.Debugf(`Created RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	revert = false

	return nil
}

func (s *storageCeph) ContainerCreateFromImage(container container, fingerprint string) error {
	logger.Debugf(`Creating RBD storage volume for container "%s" on `+
		`storage pool "%s"`, s.volume.Name, s.pool.Name)

	revert := true

	containerPath := container.Path()
	containerName := container.Name()
	containerPoolVolumeMntPoint := getContainerMountPoint(s.pool.Name,
		containerName)

	imageStoragePoolLockID := getImageCreateLockID(s.pool.Name, fingerprint)
	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[imageStoragePoolLockID]; ok {
		apolloStorageMapLock.Unlock()
		if _, ok := <-waitChannel; ok {
			logger.Warnf(`Received value over semaphore. This ` +
				`should not have happened`)
		}
	} else {
		apolloStorageOngoingOperationMap[imageStoragePoolLockID] = make(chan bool)
		apolloStorageMapLock.Unlock()

		var imgerr error
		if !cephRBDVolumeExists(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName) {
			imgerr = s.ImageCreate(fingerprint)
		}

		apolloStorageMapLock.Lock()
		if waitChannel, ok := apolloStorageOngoingOperationMap[imageStoragePoolLockID]; ok {
			close(waitChannel)
			delete(apolloStorageOngoingOperationMap, imageStoragePoolLockID)
		}
		apolloStorageMapLock.Unlock()

		if imgerr != nil {
			return imgerr
		}
	}

	err := cephRBDCloneCreate(s.ClusterName, s.OSDPoolName, fingerprint,
		storagePoolVolumeTypeNameImage, "readonly", s.OSDPoolName,
		containerName, storagePoolVolumeTypeNameContainer, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to clone new RBD storage volume for `+
			`container "%s": %s`, containerName, err)
		return err
	}
	logger.Debugf(`Cloned new RBD storage volume for container "%s"`,
		containerName)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName,
			containerName, storagePoolVolumeTypeNameContainer,
			s.UserName)
		if err != nil {
			logger.Warnf(`Failed to delete RBD storage volume `+
				`for container "%s": %s`, containerName, err)
		}
	}()

	_, err = cephRBDVolumeMap(s.ClusterName, s.OSDPoolName, containerName,
		storagePoolVolumeTypeNameContainer, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to map RBD storage volume for container `+
			`"%s"`, containerName)
		return err
	}
	logger.Debugf(`Mapped RBD storage volume for container "%s"`,
		containerName)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
			containerName, storagePoolVolumeTypeNameContainer,
			s.UserName, true)
		if err != nil {
			logger.Warnf(`Failed to unmap RBD storage volume `+
				`for container "%s": %s`, containerName, err)
		}
	}()

	privileged := container.IsPrivileged()
	err = createContainerMountpoint(containerPoolVolumeMntPoint,
		containerPath, privileged)
	if err != nil {
		logger.Errorf(`Failed to create mountpoint "%s" for container `+
			`"%s" for RBD storage volume: %s`,
			containerPoolVolumeMntPoint, containerName, err)
		return err
	}
	logger.Debugf(`Created mountpoint "%s" for container "%s" for RBD `+
		`storage volume`, containerPoolVolumeMntPoint, containerName)

	defer func() {
		if !revert {
			return
		}

		err := os.Remove(containerPoolVolumeMntPoint)
		if err != nil {
			logger.Warnf(`Failed to delete mountpoint "%s" for `+
				`container "%s" for RBD storage volume: %s`,
				containerPoolVolumeMntPoint, containerName, err)
		}
	}()

	ourMount, err := s.ContainerMount(container)
	if err != nil {
		return err
	}
	if ourMount {
		defer s.ContainerUmount(containerName, containerPath)
	}

	if !privileged {
		err := s.shiftRootfs(container)
		if err != nil {
			logger.Errorf(`Failed to shift rootfs for container `+
				`"%s": %s`, containerName, err)
			return err
		}
		logger.Debugf(`Shifted rootfs for container "%s"`, containerName)

		err = os.Chmod(containerPoolVolumeMntPoint, 0755)
		if err != nil {
			logger.Errorf(`Failed change mountpoint "%s" `+
				`permissions to 0755 for container "%s" for `+
				`RBD storage volume: %s`,
				containerPoolVolumeMntPoint, containerName, err)
			return err
		}
		logger.Debugf(`Changed mountpoint "%s" permissions to 0755 for `+
			`container "%s" for RBD storage volume`,
			containerPoolVolumeMntPoint, containerName)
	} else {
		err := os.Chmod(containerPoolVolumeMntPoint, 0700)
		if err != nil {
			logger.Errorf(`Failed change mountpoint "%s" `+
				`permissions to 0700 for container "%s" for `+
				`RBD storage volume: %s`,
				containerPoolVolumeMntPoint, containerName, err)
			return err
		}
		logger.Debugf(`Changed mountpoint "%s" permissions to 0700 `+
			`for container "%s" for RBD storage volume`,
			containerPoolVolumeMntPoint, containerName)
	}

	err = container.TemplateApply("create")
	if err != nil {
		logger.Errorf(`Failed to apply create template for container `+
			`"%s": %s`, containerName, err)
		return err
	}
	logger.Debugf(`Applied create template for container "%s"`,
		containerName)

	logger.Debugf(`Created RBD storage volume for container "%s" on `+
		`storage pool "%s"`, s.volume.Name, s.pool.Name)

	revert = false

	return nil
}

func (s *storageCeph) ContainerCanRestore(container container, sourceContainer container) error {
	return nil
}

func (s *storageCeph) ContainerDelete(container container) error {
	containerName := container.Name()
	logger.Debugf(`Deleting RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	// umount
	containerPath := container.Path()
	_, err := s.ContainerUmount(containerName, containerPath)
	if err != nil {
		return err
	}

	// delete
	ret := cephContainerDelete(s.ClusterName, s.OSDPoolName, containerName,
		storagePoolVolumeTypeNameContainer, s.UserName)
	if ret < 0 {
		msg := fmt.Sprintf(`Failed to delete RBD storage volume for `+
			`container "%s" on storage pool "%s"`, containerName, s.pool.Name)
		logger.Errorf(msg)
		return fmt.Errorf(msg)
	}

	containerMntPoint := getContainerMountPoint(s.pool.Name, containerName)
	err = deleteContainerMountpoint(containerMntPoint, containerPath, s.GetStorageTypeName())
	if err != nil {
		logger.Errorf(`Failed to delete mountpoint %s for RBD storage `+
			`volume of container "%s" for RBD storage volume on `+
			`storage pool "%s": %s`, containerMntPoint,
			containerName, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Deleted mountpoint %s for RBD storage volume of `+
		`container "%s" for RBD storage volume on storage pool "%s"`,
		containerMntPoint, containerName, s.pool.Name)

	logger.Debugf(`Deleted RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)
	return nil
}

func (s *storageCeph) ContainerCopy(target container, source container,
	containerOnly bool) error {
	sourceContainerName := source.Name()
	logger.Debugf(`Copying RBD container storage %s -> %s`,
		sourceContainerName, target.Name())

	revert := true

	ourStart, err := source.StorageStart()
	if err != nil {
		logger.Errorf(`Failed to initialize storage for container `+
			`"%s": %s`, sourceContainerName, err)
		return err
	}
	logger.Debugf(`Initialized storage for container "%s"`,
		sourceContainerName)
	if ourStart {
		defer source.StorageStop()
	}

	_, sourcePool := source.Storage().GetContainerPoolInfo()
	_, targetPool := target.Storage().GetContainerPoolInfo()
	if sourcePool != targetPool {
		return fmt.Errorf(`Copying containers between different ` +
			`storage pools is not implemented`)
	}

	snapshots, err := source.Snapshots()
	if err != nil {
		logger.Errorf(`Failed to retrieve snapshots of container `+
			`"%s": %s`, sourceContainerName, err)
		return err
	}
	logger.Debugf(`Retrieved snapshots of container "%s"`,
		sourceContainerName)

	targetContainerName := target.Name()
	targetContainerMountPoint := getContainerMountPoint(s.pool.Name,
		targetContainerName)
	if containerOnly || len(snapshots) == 0 {
		if s.pool.Config["ceph.rbd.clone_copy"] != "" &&
			!shared.IsTrue(s.pool.Config["ceph.rbd.clone_copy"]) {
			err = s.copyWithoutSnapshotsFull(target, source)
		} else {
			err = s.copyWithoutSnapshotsSparse(target, source)
		}
		if err != nil {
			logger.Errorf(`Failed to copy RBD container storage `+
				`%s -> %s`, sourceContainerName, target.Name())
			return err
		}

		logger.Debugf(`Copied RBD container storage %s -> %s`,
			sourceContainerName, target.Name())
		return nil
	} else {
		logger.Debugf(`Creating non-sparse copy of RBD storage volume `+
			`for container "%s" -> "%s" including snapshots`,
			sourceContainerName, targetContainerName)

		// create mountpoint for container
		targetContainerPath := target.Path()
		targetContainerMountPoint := getContainerMountPoint(
			s.pool.Name,
			targetContainerName)
		err = createContainerMountpoint(
			targetContainerMountPoint,
			targetContainerPath,
			target.IsPrivileged())
		if err != nil {
			logger.Errorf(`Failed to create mountpoint "%s" for `+
				`RBD storage volume "%s" on storage pool `+
				`"%s": %s"`, targetContainerMountPoint,
				s.volume.Name, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Created mountpoint "%s" for RBD storage `+
			`volume "%s" on storage pool "%s"`,
			targetContainerMountPoint, s.volume.Name, s.pool.Name)

		defer func() {
			if !revert {
				return
			}

			err = deleteContainerMountpoint(
				targetContainerMountPoint,
				targetContainerPath,
				"")
			if err != nil {
				logger.Warnf(`Failed to delete mountpoint `+
					`"%s" for RBD storage volume "%s" on `+
					`storage pool "%s": %s"`,
					targetContainerMountPoint,
					s.volume.Name, s.pool.Name, err)
			}
		}()

		// create empty dummy volume
		err = cephRBDVolumeCreate(s.ClusterName, s.OSDPoolName,
			targetContainerName, storagePoolVolumeTypeNameContainer,
			"0", s.UserName)
		if err != nil {
			logger.Errorf(`Failed to create RBD storage volume "%s" on `+
				`storage pool "%s": %s`, targetContainerName,
				s.pool.Name, err)
			return err
		}
		logger.Debugf(`Created RBD storage volume "%s" on storage pool "%s"`,
			targetContainerName, s.pool.Name)

		defer func() {
			if !revert {
				return
			}

			err := cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName,
				targetContainerName,
				storagePoolVolumeTypeNameContainer, s.UserName)
			if err != nil {
				logger.Warnf(`Failed to delete RBD storage `+
					`volume "%s" on storage pool "%s": %s`,
					targetContainerName, s.pool.Name, err)
			}
		}()

		// receive over the dummy volume we created above
		targetVolumeName := fmt.Sprintf(
			"%s/container_%s",
			s.OSDPoolName,
			targetContainerName)

		lastSnap := ""
		for i, snap := range snapshots {
			prev := ""
			if i > 0 {
				_, snapOnlyName, _ := containerGetParentAndSnapshotName(snapshots[i-1].Name())
				prev = fmt.Sprintf("snapshot_%s", snapOnlyName)
			}

			_, snapOnlyName, _ := containerGetParentAndSnapshotName(snap.Name())
			lastSnap = fmt.Sprintf("snapshot_%s", snapOnlyName)
			sourceVolumeName := fmt.Sprintf(
				"%s/container_%s@snapshot_%s",
				s.OSDPoolName,
				sourceContainerName,
				snapOnlyName)

			err = s.copyWithSnapshots(
				sourceVolumeName,
				targetVolumeName,
				prev)
			if err != nil {
				logger.Errorf(`Failed to copy RBD container `+
					`storage %s -> %s`, sourceVolumeName,
					targetVolumeName)
				return err
			}
			logger.Debugf(`Copied RBD container storage %s -> %s`,
				sourceVolumeName, targetVolumeName)

			defer func() {
				if !revert {
					return
				}

				err := cephRBDSnapshotDelete(s.ClusterName,
					s.OSDPoolName, targetContainerName,
					storagePoolVolumeTypeNameContainer,
					snapOnlyName, s.UserName)
				if err != nil {
					logger.Warnf(`Failed to delete RBD `+
						`container storage for `+
						`snapshot "%s" of container "%s"`,
						snapOnlyName, targetContainerName)
				}
			}()

			// create snapshot mountpoint
			newTargetName := fmt.Sprintf("%s/%s",
				targetContainerName, snapOnlyName)

			containersPath := getSnapshotMountPoint(
				s.pool.Name,
				newTargetName)

			snapshotMntPointSymlinkTarget := shared.VarPath(
				"storage-pools",
				s.pool.Name,
				"snapshots",
				targetContainerName)

			snapshotMntPointSymlink := shared.VarPath(
				"snapshots",
				targetContainerName)

			err := createSnapshotMountpoint(
				containersPath,
				snapshotMntPointSymlinkTarget,
				snapshotMntPointSymlink)
			if err != nil {
				logger.Errorf(`Failed to create mountpoint `+
					`"%s", snapshot symlink target "%s", `+
					`snapshot mountpoint symlink"%s" for `+
					`RBD storage volume "%s" on storage `+
					`pool "%s": %s`, containersPath,
					snapshotMntPointSymlinkTarget,
					snapshotMntPointSymlink, s.volume.Name,
					s.pool.Name, err)
				return err
			}
			logger.Debugf(`Created mountpoint "%s", snapshot `+
				`symlink target "%s", snapshot mountpoint `+
				`symlink"%s" for RBD storage volume "%s" on `+
				`storage pool "%s"`, containersPath,
				snapshotMntPointSymlinkTarget,
				snapshotMntPointSymlink, s.volume.Name,
				s.pool.Name)

			defer func() {
				if !revert {
					return
				}

				err = deleteSnapshotMountpoint(
					containersPath,
					snapshotMntPointSymlinkTarget,
					snapshotMntPointSymlink)
				if err != nil {
					logger.Warnf(`Failed to delete `+
						`mountpoint "%s", snapshot `+
						`symlink target "%s", `+
						`snapshot mountpoint `+
						`symlink "%s" for RBD storage `+
						`volume "%s" on storage pool `+
						`"%s": %s`, containersPath,
						snapshotMntPointSymlinkTarget,
						snapshotMntPointSymlink,
						s.volume.Name, s.pool.Name, err)
				}
			}()
		}

		// copy snapshot
		sourceVolumeName := fmt.Sprintf(
			"%s/container_%s",
			s.OSDPoolName,
			sourceContainerName)
		err = s.copyWithSnapshots(
			sourceVolumeName,
			targetVolumeName,
			lastSnap)
		if err != nil {
			logger.Errorf(`Failed to copy RBD container storage `+
				`%s -> %s`, sourceVolumeName, targetVolumeName)
			return err
		}
		logger.Debugf(`Copied RBD container storage %s -> %s`,
			sourceVolumeName, targetVolumeName)

		// Note, we don't need to register another cleanup function for
		// the actual container's storage volume since we already
		// registered one above for the dummy volume we created.

		// map the container's volume
		_, err = cephRBDVolumeMap(s.ClusterName, s.OSDPoolName,
			targetContainerName, storagePoolVolumeTypeNameContainer,
			s.UserName)
		if err != nil {
			logger.Errorf(`Failed to map RBD storage volume for `+
				`container "%s" on storage pool "%s": %s`,
				targetContainerName, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Mapped RBD storage volume for container "%s" `+
			`on storage pool "%s"`, targetContainerName, s.pool.Name)

		logger.Debugf(`Created non-sparse copy of RBD storage volume `+
			`for container "%s" -> "%s" including snapshots`,
			sourceContainerName, targetContainerName)
	}

	ourMount, err := s.ContainerMount(target)
	if err != nil {
		return err
	}
	if ourMount {
		defer s.ContainerUmount(target.Name(), targetContainerMountPoint)
	}

	err = target.TemplateApply("copy")
	if err != nil {
		logger.Errorf(`Failed to apply copy template for container `+
			`"%s": %s`, target.Name(), err)
		return err
	}
	logger.Debugf(`Applied copy template for container "%s"`, target.Name())

	logger.Debugf(`Copied RBD container storage %s -> %s`,
		sourceContainerName, target.Name())

	revert = false

	return nil
}

func (s *storageCeph) ContainerMount(c container) (bool, error) {
	name := c.Name()
	logger.Debugf("Mounting RBD storage volume for container \"%s\" on storage pool \"%s\".", s.volume.Name, s.pool.Name)

	RBDFilesystem := s.getRBDFilesystem()
	containerMntPoint := getContainerMountPoint(s.pool.Name, name)
	if shared.IsSnapshot(name) {
		containerMntPoint = getSnapshotMountPoint(s.pool.Name, name)
	}

	containerMountLockID := getContainerMountLockID(s.pool.Name, name)
	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[containerMountLockID]; ok {
		apolloStorageMapLock.Unlock()
		if _, ok := <-waitChannel; ok {
			logger.Warnf("Received value over semaphore. This should not have happened.")
		}
		// Give the benefit of the doubt and assume that the other
		// thread actually succeeded in mounting the storage volume.
		logger.Debugf("RBD storage volume for container \"%s\" on storage pool \"%s\" appears to be already mounted", s.volume.Name, s.pool.Name)
		return false, nil
	}

	apolloStorageOngoingOperationMap[containerMountLockID] = make(chan bool)
	apolloStorageMapLock.Unlock()

	var ret int
	var mounterr error
	ourMount := false
	RBDDevPath := ""
	if !shared.IsMountPoint(containerMntPoint) {
		RBDDevPath, ret = getRBDMappedDevPath(s.ClusterName,
			s.OSDPoolName, storagePoolVolumeTypeNameContainer,
			name, true, s.UserName)
		if ret >= 0 {
			mountFlags, mountOptions := apolloResolveMountoptions(s.getRBDMountOptions())
			mounterr = tryMount(RBDDevPath, containerMntPoint,
				RBDFilesystem, mountFlags, mountOptions)
			ourMount = true
		}
	}

	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[containerMountLockID]; ok {
		close(waitChannel)
		delete(apolloStorageOngoingOperationMap, containerMountLockID)
	}
	apolloStorageMapLock.Unlock()

	if mounterr != nil || ret < 0 {
		logger.Errorf("Failed to mount RBD storage volume for container \"%s\": %s", s.volume.Name, mounterr)
		return false, mounterr
	}

	logger.Debugf("Mounted RBD storage volume for container \"%s\" on storage pool \"%s\".", s.volume.Name, s.pool.Name)
	return ourMount, nil
}

func (s *storageCeph) ContainerUmount(name string, path string) (bool, error) {
	logger.Debugf("Unmounting RBD storage volume for container \"%s\" on storage pool \"%s\".", s.volume.Name, s.pool.Name)

	containerMntPoint := getContainerMountPoint(s.pool.Name, name)
	if shared.IsSnapshot(name) {
		containerMntPoint = getSnapshotMountPoint(s.pool.Name, name)
	}

	containerUmountLockID := getContainerUmountLockID(s.pool.Name, name)
	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[containerUmountLockID]; ok {
		apolloStorageMapLock.Unlock()
		if _, ok := <-waitChannel; ok {
			logger.Warnf("Received value over semaphore. This should not have happened.")
		}
		// Give the benefit of the doubt and assume that the other
		// thread actually succeeded in unmounting the storage volume.
		logger.Debugf("RBD storage volume for container \"%s\" on storage pool \"%s\" appears to be already unmounted", s.volume.Name, s.pool.Name)
		return false, nil
	}

	apolloStorageOngoingOperationMap[containerUmountLockID] = make(chan bool)
	apolloStorageMapLock.Unlock()

	var mounterr error
	ourUmount := false
	if shared.IsMountPoint(containerMntPoint) {
		mounterr = tryUnmount(containerMntPoint, 0)
		ourUmount = true
	}

	apolloStorageMapLock.Lock()
	if waitChannel, ok := apolloStorageOngoingOperationMap[containerUmountLockID]; ok {
		close(waitChannel)
		delete(apolloStorageOngoingOperationMap, containerUmountLockID)
	}
	apolloStorageMapLock.Unlock()

	if mounterr != nil {
		logger.Errorf("Failed to unmount RBD storage volume for container \"%s\": %s", s.volume.Name, mounterr)
		return false, mounterr
	}

	logger.Debugf("Unmounted RBD storage volume for container \"%s\" on storage pool \"%s\".", s.volume.Name, s.pool.Name)
	return ourUmount, nil
}

func (s *storageCeph) ContainerRename(c container, newName string) error {
	oldName := c.Name()
	containerPath := c.Path()

	revert := true

	logger.Debugf(`Renaming RBD storage volume for container "%s" from `+
		`"%s" to "%s"`, oldName, oldName, newName)

	// unmount
	_, err := s.ContainerUmount(oldName, containerPath)
	if err != nil {
		return err
	}

	// unmap
	err = cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName, oldName,
		storagePoolVolumeTypeNameContainer, s.UserName, true)
	if err != nil {
		logger.Errorf(`Failed to unmap RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`, oldName,
			s.pool.Name, err)
		return err
	}
	logger.Debugf(`Unmapped RBD storage volume for container "%s" on `+
		`storage pool "%s"`, oldName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		_, err := cephRBDVolumeMap(s.ClusterName, s.OSDPoolName,
			oldName, storagePoolVolumeTypeNameContainer, s.UserName)
		if err != nil {
			logger.Warnf(`Failed to Map RBD storage volume `+
				`for container "%s": %s`, oldName, err)
		}
	}()

	err = cephRBDVolumeRename(s.ClusterName, s.OSDPoolName,
		storagePoolVolumeTypeNameContainer, oldName, newName, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to rename RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`,
			oldName, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Renamed RBD storage volume for container "%s" on `+
		`storage pool "%s"`, oldName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err = cephRBDVolumeRename(s.ClusterName, s.OSDPoolName,
			storagePoolVolumeTypeNameContainer, newName, oldName,
			s.UserName)
		if err != nil {
			logger.Warnf(`Failed to rename RBD storage volume for `+
				`container "%s" on storage pool "%s": %s`,
				newName, s.pool.Name, err)
		}
	}()

	// map
	_, err = cephRBDVolumeMap(s.ClusterName, s.OSDPoolName, newName,
		storagePoolVolumeTypeNameContainer, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to map RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`, newName,
			s.pool.Name, err)
		return err
	}
	logger.Debugf(`Mapped RBD storage volume for container "%s" on `+
		`storage pool "%s"`, newName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName, newName,
			storagePoolVolumeTypeNameContainer, s.UserName, true)
		if err != nil {
			logger.Warnf(`Failed to unmap RBD storage volume `+
				`for container "%s": %s`, newName, err)
		}
	}()

	// Create new mountpoint on the storage pool.
	oldContainerMntPoint := getContainerMountPoint(s.pool.Name, oldName)
	oldContainerMntPointSymlink := containerPath
	newContainerMntPoint := getContainerMountPoint(s.pool.Name, newName)
	newContainerMntPointSymlink := shared.VarPath("containers", newName)
	err = renameContainerMountpoint(
		oldContainerMntPoint,
		oldContainerMntPointSymlink,
		newContainerMntPoint,
		newContainerMntPointSymlink)
	if err != nil {
		return err
	}

	defer func() {
		if !revert {
			return
		}

		renameContainerMountpoint(newContainerMntPoint,
			newContainerMntPointSymlink, oldContainerMntPoint,
			oldContainerMntPointSymlink)
	}()

	// Rename the snapshot mountpoint on the storage pool.
	oldSnapshotMntPoint := getSnapshotMountPoint(s.pool.Name, oldName)
	newSnapshotMntPoint := getSnapshotMountPoint(s.pool.Name, newName)
	if shared.PathExists(oldSnapshotMntPoint) {
		err := os.Rename(oldSnapshotMntPoint, newSnapshotMntPoint)
		if err != nil {
			return err
		}
	}

	defer func() {
		if !revert {
			return
		}

		os.Rename(newSnapshotMntPoint, oldSnapshotMntPoint)
	}()

	// Remove old symlink.
	oldSnapshotPath := shared.VarPath("snapshots", oldName)
	if shared.PathExists(oldSnapshotPath) {
		err := os.Remove(oldSnapshotPath)
		if err != nil {
			return err
		}
	}

	defer func() {
		if !revert {
			return
		}

		os.Symlink(oldSnapshotMntPoint, oldSnapshotPath)
	}()

	// Create new symlink.
	newSnapshotPath := shared.VarPath("snapshots", newName)
	if shared.PathExists(newSnapshotPath) {
		err := os.Symlink(newSnapshotMntPoint, newSnapshotPath)
		if err != nil {
			return err
		}
	}

	logger.Debugf(`Renamed RBD storage volume for container "%s" from `+
		`"%s" to "%s"`, oldName, oldName, newName)

	revert = false

	return nil
}

func (s *storageCeph) ContainerRestore(target container, source container) error {
	sourceName := source.Name()
	targetName := target.Name()

	logger.Debugf(`Restoring RBD storage volume for container "%s" from `+
		`%s to %s`, targetName, sourceName, targetName)

	// Start storage for source container
	ourSourceStart, err := source.StorageStart()
	if err != nil {
		logger.Errorf(`Failed to initialize storage for container `+
			`"%s": %s`, sourceName, err)
		return err
	}
	logger.Debugf(`Initialized storage for container "%s"`, sourceName)
	if ourSourceStart {
		defer source.StorageStop()
	}

	// Start storage for target container
	ourTargetStart, err := target.StorageStart()
	if err != nil {
		logger.Errorf(`Failed to initialize storage for container `+
			`"%s": %s`, targetName, err)
		return err
	}
	logger.Debugf(`Initialized storage for container "%s"`, targetName)
	if ourTargetStart {
		defer target.StorageStop()
	}

	sourceContainerOnlyName, sourceSnapshotOnlyName, _ := containerGetParentAndSnapshotName(sourceName)
	prefixedSourceSnapOnlyName := fmt.Sprintf("snapshot_%s", sourceSnapshotOnlyName)
	err = cephRBDVolumeRestore(s.ClusterName, s.OSDPoolName,
		sourceContainerOnlyName, storagePoolVolumeTypeNameContainer,
		prefixedSourceSnapOnlyName, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to restore RBD storage volume for `+
			`container "%s" from "%s": %s`,
			targetName, sourceName, err)
		return err
	}

	logger.Debugf(`Restored RBD storage volume for container "%s" from `+
		`%s to %s`, targetName, sourceName, targetName)
	return nil
}

func (s *storageCeph) ContainerGetUsage(container container) (int64, error) {
	return -1, fmt.Errorf("RBD quotas are currently not supported")
}

func (s *storageCeph) ContainerSnapshotCreate(snapshotContainer container,
	sourceContainer container) error {
	targetContainerName := snapshotContainer.Name()
	logger.Debugf(`Creating RBD storage volume for snapshot "%s" on `+
		`storage pool "%s"`, targetContainerName, s.pool.Name)

	revert := true

	sourceContainerName := sourceContainer.Name()
	_, targetSnapshotOnlyName, _ := containerGetParentAndSnapshotName(targetContainerName)
	targetSnapshotName := fmt.Sprintf("snapshot_%s", targetSnapshotOnlyName)
	err := cephRBDSnapshotCreate(s.ClusterName, s.OSDPoolName,
		sourceContainerName, storagePoolVolumeTypeNameContainer,
		targetSnapshotName, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to create snapshot for RBD storage `+
			`volume for image "%s" on storage pool "%s": %s`,
			targetContainerName, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Created snapshot for RBD storage volume for image `+
		`"%s" on storage pool "%s"`, targetContainerName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDSnapshotDelete(s.ClusterName, s.OSDPoolName,
			sourceContainerName, storagePoolVolumeTypeNameContainer,
			targetSnapshotName, s.UserName)
		if err != nil {
			logger.Warnf(`Failed to delete RBD `+
				`container storage for `+
				`snapshot "%s" of container "%s"`,
				targetSnapshotOnlyName, sourceContainerName)
		}
	}()

	targetContainerMntPoint := getSnapshotMountPoint(s.pool.Name, targetContainerName)
	sourceName, _, _ := containerGetParentAndSnapshotName(sourceContainerName)
	snapshotMntPointSymlinkTarget := shared.VarPath("storage-pools",
		s.pool.Name, "snapshots", sourceName)
	snapshotMntPointSymlink := shared.VarPath("snapshots", sourceName)
	err = createSnapshotMountpoint(
		targetContainerMntPoint,
		snapshotMntPointSymlinkTarget,
		snapshotMntPointSymlink)
	if err != nil {
		logger.Errorf(`Failed to create mountpoint "%s", snapshot `+
			`symlink target "%s", snapshot mountpoint symlink"%s" `+
			`for RBD storage volume "%s" on storage pool "%s": %s`,
			targetContainerMntPoint, snapshotMntPointSymlinkTarget,
			snapshotMntPointSymlink, s.volume.Name, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Created mountpoint "%s", snapshot symlink target `+
		`"%s", snapshot mountpoint symlink"%s" for RBD storage `+
		`volume "%s" on storage pool "%s"`, targetContainerMntPoint,
		snapshotMntPointSymlinkTarget, snapshotMntPointSymlink,
		s.volume.Name, s.pool.Name)

	logger.Debugf(`Created RBD storage volume for snapshot "%s" on `+
		`storage pool "%s"`, targetContainerName, s.pool.Name)

	revert = false

	return nil
}

func (s *storageCeph) ContainerSnapshotDelete(snapshotContainer container) error {
	logger.Debugf(`Deleting RBD storage volume for snapshot "%s" on `+
		`storage pool "%s"`, s.volume.Name, s.pool.Name)

	snapshotContainerName := snapshotContainer.Name()
	sourceContainerName, sourceContainerSnapOnlyName, _ :=
		containerGetParentAndSnapshotName(snapshotContainerName)
	snapshotName := fmt.Sprintf("snapshot_%s", sourceContainerSnapOnlyName)
	ret := cephContainerSnapshotDelete(s.ClusterName, s.OSDPoolName,
		sourceContainerName, storagePoolVolumeTypeNameContainer,
		snapshotName, s.UserName)
	if ret < 0 {
		msg := fmt.Sprintf(`Failed to delete RBD storage volume for `+
			`snapshot "%s" on storage pool "%s"`,
			snapshotContainerName, s.pool.Name)
		logger.Errorf(msg)
		return fmt.Errorf(msg)
	}

	snapshotContainerMntPoint := getSnapshotMountPoint(s.pool.Name,
		snapshotContainerName)
	if shared.PathExists(snapshotContainerMntPoint) {
		err := os.RemoveAll(snapshotContainerMntPoint)
		if err != nil {
			logger.Errorf(`Failed to delete mountpoint "%s" of `+
				`RBD snapshot "%s" of container "%s" on `+
				`storage pool "%s": %s`,
				snapshotContainerMntPoint,
				sourceContainerSnapOnlyName,
				sourceContainerName, s.OSDPoolName, err)
			return err
		}
		logger.Debugf(`Deleted mountpoint "%s" of RBD snapshot "%s" `+
			`of container "%s" on storage pool "%s"`,
			snapshotContainerMntPoint, sourceContainerSnapOnlyName,
			sourceContainerName, s.OSDPoolName)
	}

	// check if snapshot directory is empty
	snapshotContainerPath := getSnapshotMountPoint(s.pool.Name,
		sourceContainerName)
	empty, _ := shared.PathIsEmpty(snapshotContainerPath)
	if empty == true {
		// remove snapshot directory for container
		err := os.Remove(snapshotContainerPath)
		if err != nil {
			logger.Errorf(`Failed to delete snapshot directory  `+
				`"%s" of RBD snapshot "%s" of container "%s" `+
				`on storage pool "%s": %s`,
				snapshotContainerPath,
				sourceContainerSnapOnlyName,
				sourceContainerName, s.OSDPoolName, err)
			return err
		}
		logger.Debugf(`Deleted snapshot directory  "%s" of RBD `+
			`snapshot "%s" of container "%s" on storage pool "%s"`,
			snapshotContainerPath, sourceContainerSnapOnlyName,
			sourceContainerName, s.OSDPoolName)

		// remove the snapshot symlink if possible
		snapshotSymlink := shared.VarPath("snapshots",
			sourceContainerName)
		if shared.PathExists(snapshotSymlink) {
			err := os.Remove(snapshotSymlink)
			if err != nil {
				logger.Errorf(`Failed to delete snapshot `+
					`symlink "%s" of RBD snapshot "%s" of `+
					`container "%s" on storage pool "%s": %s`,
					snapshotSymlink,
					sourceContainerSnapOnlyName,
					sourceContainerName, s.OSDPoolName, err)
				return err
			}
			logger.Debugf(`Deleted snapshot symlink "%s" of RBD `+
				`snapshot "%s" of container "%s" on storage `+
				`pool "%s"`, snapshotSymlink,
				sourceContainerSnapOnlyName,
				sourceContainerName, s.OSDPoolName)
		}
	}

	logger.Debugf(`Deleted RBD storage volume for snapshot "%s" on `+
		`storage pool "%s"`, s.volume.Name, s.pool.Name)
	return nil
}

func (s *storageCeph) ContainerSnapshotRename(c container, newName string) error {
	oldName := c.Name()
	logger.Debugf(`Renaming RBD storage volume for snapshot "%s" from `+
		`"%s" to "%s"`, oldName, oldName, newName)

	revert := true

	containerOnlyName, snapOnlyName, _ := containerGetParentAndSnapshotName(oldName)
	oldSnapOnlyName := fmt.Sprintf("snapshot_%s", snapOnlyName)
	_, newSnapOnlyName, _ := containerGetParentAndSnapshotName(newName)
	newSnapOnlyName = fmt.Sprintf("snapshot_%s", newSnapOnlyName)
	err := cephRBDVolumeSnapshotRename(s.ClusterName, s.OSDPoolName,
		containerOnlyName, storagePoolVolumeTypeNameContainer, oldSnapOnlyName,
		newSnapOnlyName, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to rename RBD storage volume for `+
			`snapshot "%s" from "%s" to "%s": %s`, oldName, oldName,
			newName, err)
		return err
	}

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeSnapshotRename(s.ClusterName, s.OSDPoolName,
			containerOnlyName, storagePoolVolumeTypeNameContainer,
			newSnapOnlyName, oldSnapOnlyName, s.UserName)
		if err != nil {
			logger.Warnf(`Failed to rename RBD storage `+
				`volume for container "%s" on storage `+
				`pool "%s": %s`, oldName, s.pool.Name,
				err)
		}
	}()

	oldSnapshotMntPoint := getSnapshotMountPoint(s.pool.Name, oldName)
	newSnapshotMntPoint := getSnapshotMountPoint(s.pool.Name, newName)
	err = os.Rename(oldSnapshotMntPoint, newSnapshotMntPoint)
	if err != nil {
		logger.Errorf(`Failed to rename mountpoint for RBD storage `+
			`volume for snapshot "%s" from "%s" to "%s": %s`,
			oldName, oldSnapshotMntPoint, newSnapshotMntPoint, err)
		return err
	}
	logger.Debugf(`Renamed mountpoint for RBD storage volume for `+
		`snapshot "%s" from "%s" to "%s"`, oldName, oldSnapshotMntPoint,
		newSnapshotMntPoint)

	logger.Debugf(`Renamed RBD storage volume for snapshot "%s" from `+
		`"%s" to "%s"`, oldName, oldName, newName)

	revert = false

	return nil
}

func (s *storageCeph) ContainerSnapshotStart(c container) (bool, error) {
	containerName := c.Name()
	logger.Debugf(`Initializing RBD storage volume for snapshot "%s" `+
		`on storage pool "%s"`, containerName, s.pool.Name)

	revert := true

	containerOnlyName, snapOnlyName, _ := containerGetParentAndSnapshotName(containerName)

	// protect
	prefixedSnapOnlyName := fmt.Sprintf("snapshot_%s", snapOnlyName)
	err := cephRBDSnapshotProtect(s.ClusterName, s.OSDPoolName,
		containerOnlyName, storagePoolVolumeTypeNameContainer,
		prefixedSnapOnlyName, s.UserName)
	if err != nil {
		logger.Errorf(`Failed to protect snapshot of RBD storage `+
			`volume for container "%s" on storage pool "%s": %s`,
			containerName, s.pool.Name, err)
		return false, err
	}
	logger.Debugf(`Protected snapshot of RBD storage volume for container `+
		`"%s" on storage pool "%s"`, containerName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDSnapshotUnprotect(s.ClusterName, s.OSDPoolName,
			containerOnlyName, storagePoolVolumeTypeNameContainer,
			prefixedSnapOnlyName, s.UserName)
		if err != nil {
			logger.Warnf(`Failed to unprotect snapshot of RBD `+
				`storage volume for container "%s" on storage `+
				`pool "%s": %s`, containerName, s.pool.Name, err)
		}
	}()

	cloneName := fmt.Sprintf("%s_%s_start_clone", containerOnlyName, snapOnlyName)
	// clone
	err = cephRBDCloneCreate(s.ClusterName, s.OSDPoolName,
		containerOnlyName, storagePoolVolumeTypeNameContainer,
		prefixedSnapOnlyName, s.OSDPoolName, cloneName, "snapshots",
		s.UserName)
	if err != nil {
		logger.Errorf(`Failed to create clone of RBD storage volume `+
			`for container "%s" on storage pool "%s": %s`,
			containerName, s.pool.Name, err)
		return false, err
	}
	logger.Debugf(`Created clone of RBD storage volume for container "%s" `+
		`on storage pool "%s"`, containerName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		// delete
		err = cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName,
			cloneName, "snapshots", s.UserName)
		if err != nil {
			logger.Errorf(`Failed to delete clone of RBD storage `+
				`volume for container "%s" on storage pool `+
				`"%s": %s`, containerName, s.pool.Name, err)
		}
	}()

	// map
	RBDDevPath, err := cephRBDVolumeMap(s.ClusterName, s.OSDPoolName,
		cloneName, "snapshots", s.UserName)
	if err != nil {
		logger.Errorf(`Failed to map RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`,
			containerName, s.pool.Name, err)
		return false, err
	}
	logger.Debugf(`Mapped RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	defer func() {
		if !revert {
			return
		}

		err := cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
			cloneName, "snapshots", s.UserName, true)
		if err != nil {
			logger.Warnf(`Failed to unmap RBD storage volume for `+
				`container "%s" on storage pool "%s": %s`,
				containerName, s.pool.Name, err)
		}
	}()

	containerMntPoint := getSnapshotMountPoint(s.pool.Name, containerName)
	RBDFilesystem := s.getRBDFilesystem()
	mountFlags, mountOptions := apolloResolveMountoptions(s.getRBDMountOptions())
	err = tryMount(
		RBDDevPath,
		containerMntPoint,
		RBDFilesystem,
		mountFlags,
		mountOptions)
	if err != nil {
		logger.Errorf("Failed to mount RBD device %s onto %s: %s",
			RBDDevPath, containerMntPoint, err)
		return false, err
	}
	logger.Debugf("Mounted RBD device %s onto %s", RBDDevPath,
		containerMntPoint)

	logger.Debugf(`Initialized RBD storage volume for snapshot "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	revert = false

	return true, nil
}

func (s *storageCeph) ContainerSnapshotStop(c container) (bool, error) {
	containerName := c.Name()
	logger.Debugf(`Stopping RBD storage volume for snapshot "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	containerMntPoint := getSnapshotMountPoint(s.pool.Name, containerName)
	err := tryUnmount(containerMntPoint, syscall.MNT_DETACH)
	if err != nil {
		logger.Errorf("Failed to unmount %s: %s", containerMntPoint,
			err)
		return false, err
	}
	logger.Debugf("Unmounted %s", containerMntPoint)

	containerOnlyName, snapOnlyName, _ := containerGetParentAndSnapshotName(containerName)
	cloneName := fmt.Sprintf("%s_%s_start_clone", containerOnlyName, snapOnlyName)
	// unmap
	err = cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName, cloneName,
		"snapshots", s.UserName, true)
	if err != nil {
		logger.Errorf(`Failed to unmap RBD storage volume for `+
			`container "%s" on storage pool "%s": %s`,
			containerName, s.pool.Name, err)
		return false, err
	}
	logger.Debugf(`Unmapped RBD storage volume for container "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)

	// delete
	err = cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName, cloneName,
		"snapshots", s.UserName)
	if err != nil {
		logger.Errorf(`Failed to delete clone of RBD storage volume `+
			`for container "%s" on storage pool "%s": %s`,
			containerName, s.pool.Name, err)
		return false, err
	}
	logger.Debugf(`Deleted clone of RBD storage volume for container "%s" `+
		`on storage pool "%s"`, containerName, s.pool.Name)

	logger.Debugf(`Stopped RBD storage volume for snapshot "%s" on `+
		`storage pool "%s"`, containerName, s.pool.Name)
	return true, nil
}

func (s *storageCeph) ContainerSnapshotCreateEmpty(c container) error {
	logger.Debugf(`Creating empty RBD storage volume for snapshot "%s" `+
		`on storage pool "%s" (noop)`, c.Name(), s.pool.Name)

	logger.Debugf(`Created empty RBD storage volume for snapshot "%s" `+
		`on storage pool "%s" (noop)`, c.Name(), s.pool.Name)
	return nil
}

func (s *storageCeph) ImageCreate(fingerprint string) error {
	logger.Debugf(`Creating RBD storage volume for image "%s" on storage `+
		`pool "%s"`, fingerprint, s.pool.Name)

	revert := true

	// create image mountpoint
	imageMntPoint := getImageMountPoint(s.pool.Name, fingerprint)
	if !shared.PathExists(imageMntPoint) {
		err := os.MkdirAll(imageMntPoint, 0700)
		if err != nil {
			logger.Errorf(`Failed to create mountpoint "%s" for RBD `+
				`storage volume for image "%s" on storage `+
				`pool "%s": %s`, imageMntPoint, fingerprint,
				s.pool.Name, err)
			return err
		}
		logger.Debugf(`Created mountpoint "%s" for RBD storage volume `+
			`for image "%s" on storage pool "%s"`, imageMntPoint,
			fingerprint, s.pool.Name)
	}

	defer func() {
		if !revert {
			return
		}

		err := os.Remove(imageMntPoint)
		if err != nil {
			logger.Warnf(`Failed to delete mountpoint "%s" for RBD `+
				`storage volume for image "%s" on storage `+
				`pool "%s": %s`, imageMntPoint, fingerprint,
				s.pool.Name, err)
		}
	}()

	prefixedType := fmt.Sprintf("zombie_%s", storagePoolVolumeTypeNameImage)
	ok := cephRBDVolumeExists(s.ClusterName, s.OSDPoolName, fingerprint,
		prefixedType, s.UserName)
	if !ok {
		logger.Debugf(`RBD storage volume for image "%s" on storage `+
			`pool "%s" does not exist`, fingerprint, s.pool.Name)

		// get size
		RBDSize, err := s.getRBDSize()
		if err != nil {
			logger.Errorf(`Failed to retrieve size of RBD storage `+
				`volume for image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Retrieve size "%s" of RBD storage volume for `+
			`image "%s" on storage pool "%s"`, RBDSize, fingerprint,
			s.pool.Name)

		// create volume
		err = cephRBDVolumeCreate(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, RBDSize,
			s.UserName)
		if err != nil {
			logger.Errorf(`Failed to create RBD storage volume `+
				`for image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Created RBD storage volume for image "%s" on `+
			`storage pool "%s"`, fingerprint, s.pool.Name)

		defer func() {
			if !revert {
				return
			}

			err := cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName,
				fingerprint, storagePoolVolumeTypeNameImage,
				s.UserName)
			if err != nil {
				logger.Warnf(`Failed to delete RBD storage `+
					`volume for image "%s" on storage `+
					`pool "%s": %s`, fingerprint,
					s.pool.Name, err)
			}
		}()

		RBDDevPath, err := cephRBDVolumeMap(s.ClusterName,
			s.OSDPoolName, fingerprint,
			storagePoolVolumeTypeNameImage, s.UserName)
		if err != nil {
			logger.Errorf(`Failed to map RBD storage volume for `+
				`image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Mapped RBD storage volume for image "%s" on `+
			`storage pool "%s"`, fingerprint, s.pool.Name)

		defer func() {
			if !revert {
				return
			}

			err := cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
				fingerprint, storagePoolVolumeTypeNameImage,
				s.UserName, true)
			if err != nil {
				logger.Warnf(`Failed to unmap RBD storage `+
					`volume for image "%s" on storage `+
					`pool "%s": %s`, fingerprint,
					s.pool.Name, err)
			}
		}()

		// get filesystem
		RBDFilesystem := s.getRBDFilesystem()
		msg, err := makeFSType(RBDDevPath, RBDFilesystem)
		if err != nil {
			logger.Errorf(`Failed to create filesystem "%s" for RBD `+
				`storage volume for image "%s" on storage `+
				`pool "%s": %s`, RBDFilesystem, fingerprint,
				s.pool.Name, msg)
			return err
		}
		logger.Debugf(`Created filesystem "%s" for RBD storage volume `+
			`for image "%s" on storage pool "%s"`, RBDFilesystem,
			fingerprint, s.pool.Name)

		// mount image
		_, err = s.ImageMount(fingerprint)
		if err != nil {
			return err
		}

		// rsync contents into image
		imagePath := shared.VarPath("images", fingerprint)
		err = unpackImage(s.d, imagePath, imageMntPoint, storageTypeCeph)
		if err != nil {
			logger.Errorf(`Failed to unpack image for RBD storage `+
				`volume for image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)

			// umount image
			s.ImageUmount(fingerprint)
			return err
		}
		logger.Debugf(`Unpacked image for RBD storage volume for `+
			`image "%s" on storage pool "%s"`, fingerprint,
			s.pool.Name)

		// umount image
		s.ImageUmount(fingerprint)

		// unmap
		err = cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName,
			true)
		if err != nil {
			logger.Errorf(`Failed to unmap RBD storage volume for `+
				`image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Unmapped RBD storage volume for image "%s" on `+
			`storage pool "%s"`, fingerprint, s.pool.Name)

		// make snapshot of volume
		err = cephRBDSnapshotCreate(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, "readonly",
			s.UserName)
		if err != nil {
			logger.Errorf(`Failed to create snapshot for RBD `+
				`storage volume for image "%s" on storage `+
				`pool "%s": %s`, fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Created snapshot for RBD storage volume for `+
			`image "%s" on storage pool "%s"`, fingerprint,
			s.pool.Name)

		defer func() {
			if !revert {
				return
			}

			err := cephRBDSnapshotDelete(s.ClusterName,
				s.OSDPoolName, fingerprint,
				storagePoolVolumeTypeNameImage, "readonly",
				s.UserName)
			if err != nil {
				logger.Warnf(`Failed to delete snapshot for `+
					`RBD storage volume for image "%s" on `+
					`storage pool "%s": %s`, fingerprint,
					s.pool.Name, err)
			}
		}()

		// protect volume so we can create clones of it
		err = cephRBDSnapshotProtect(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, "readonly",
			s.UserName)
		if err != nil {
			logger.Errorf(`Failed to protect snapshot for RBD `+
				`storage volume for image "%s" on storage `+
				`pool "%s": %s`, fingerprint, s.pool.Name,
				err)
			return err
		}
		logger.Debugf(`Protected snapshot for RBD storage volume for `+
			`image "%s" on storage pool "%s"`, fingerprint,
			s.pool.Name)

		defer func() {
			if !revert {
				return
			}

			err := cephRBDSnapshotUnprotect(s.ClusterName,
				s.OSDPoolName, fingerprint,
				storagePoolVolumeTypeNameImage, "readonly",
				s.UserName)
			if err != nil {
				logger.Warnf(`Failed to unprotect snapshot for `+
					`RBD storage volume for image "%s" on `+
					`storage pool "%s": %s`, fingerprint,
					s.pool.Name, err)
			}
		}()
	} else {
		logger.Debugf(`RBD storage volume for image "%s" on storage `+
			`pool "%s" does exist`, fingerprint, s.pool.Name)

		// unmark deleted
		err := cephRBDVolumeUnmarkDeleted(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName)
		if err != nil {
			logger.Errorf(`Failed to unmark RBD storage volume `+
				`for image "%s" on storage pool "%s" as
				zombie: %s`, fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Unmarked RBD storage volume for image "%s" on `+
			`storage pool "%s" as zombie`, fingerprint, s.pool.Name)

		defer func() {
			if !revert {
				return
			}

			err := cephRBDVolumeMarkDeleted(s.ClusterName,
				s.OSDPoolName, fingerprint,
				storagePoolVolumeTypeNameImage, s.UserName)
			if err != nil {
				logger.Warnf(`Failed to mark RBD storage `+
					`volume for image "%s" on storage `+
					`pool "%s" as zombie: %s`, fingerprint,
					s.pool.Name, err)
			}
		}()
	}

	err := s.createImageDbPoolVolume(fingerprint)
	if err != nil {
		logger.Errorf(`Failed to create database entry for RBD storage `+
			`volume for image "%s" on storage pool "%s": %s`,
			fingerprint, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Createdd database entry for RBD storage volume for `+
		`image "%s" on storage pool "%s"`, fingerprint, s.pool.Name)

	logger.Debugf(`Created RBD storage volume for image "%s" on storage `+
		`pool "%s"`, fingerprint, s.pool.Name)

	revert = false

	return nil
}

func (s *storageCeph) ImageDelete(fingerprint string) error {
	logger.Debugf(`Deleting RBD storage volume for image "%s" on storage `+
		`pool "%s"`, fingerprint, s.pool.Name)

	// try to umount but don't fail
	s.ImageUmount(fingerprint)

	// check if image has dependent snapshots
	_, err := cephRBDSnapshotListClones(s.ClusterName, s.OSDPoolName,
		fingerprint, storagePoolVolumeTypeNameImage, "readonly",
		s.UserName)
	if err != nil {
		if err != db.NoSuchObjectError {
			logger.Errorf(`Failed to list clones of RBD storage `+
				`volume for image "%s" on storage pool "%s":
				%s`, fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Retrieved no clones of RBD storage volume for `+
			`image "%s" on storage pool "%s"`, fingerprint,
			s.pool.Name)

		// unprotect snapshot
		err = cephRBDSnapshotUnprotect(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, "readonly",
			s.UserName)
		if err != nil {
			logger.Errorf(`Failed to unprotect snapshot for RBD `+
				`storage volume for image "%s" on storage `+
				`pool "%s": %s`, fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Unprotected snapshot for RBD storage volume `+
			`for image "%s" on storage pool "%s"`, fingerprint,
			s.pool.Name)

		// delete snapshots
		err = cephRBDSnapshotsPurge(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName)
		if err != nil {
			logger.Errorf(`Failed to delete snapshot for RBD `+
				`storage volume for image "%s" on storage `+
				`pool "%s": %s`, fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Deleted snapshot for RBD storage volume for `+
			`image "%s" on storage pool "%s"`, fingerprint,
			s.pool.Name)

		// unmap
		err = cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName,
			true)
		if err != nil {
			logger.Errorf(`Failed to unmap RBD storage volume for `+
				`image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Unmapped RBD storage volume for image "%s" on `+
			`storage pool "%s"`, fingerprint, s.pool.Name)

		// delete volume
		err = cephRBDVolumeDelete(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName)
		if err != nil {
			logger.Errorf(`Failed to delete RBD storage volume `+
				`for image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Deleted RBD storage volume for image "%s" on `+
			`storage pool "%s"`, fingerprint, s.pool.Name)
	} else {
		// unmap
		err = cephRBDVolumeUnmap(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName,
			true)
		if err != nil {
			logger.Errorf(`Failed to unmap RBD storage volume for `+
				`image "%s" on storage pool "%s": %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Unmapped RBD storage volume for image "%s" on `+
			`storage pool "%s"`, fingerprint, s.pool.Name)

		// mark deleted
		err := cephRBDVolumeMarkDeleted(s.ClusterName, s.OSDPoolName,
			fingerprint, storagePoolVolumeTypeNameImage, s.UserName)
		if err != nil {
			logger.Errorf(`Failed to mark RBD storage volume for `+
				`image "%s" on storage pool "%s" as zombie: %s`,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Marked RBD storage volume for image "%s" on `+
			`storage pool "%s" as zombie`, fingerprint, s.pool.Name)
	}

	err = s.deleteImageDbPoolVolume(fingerprint)
	if err != nil {
		logger.Errorf(`Failed to delete database entry for RBD `+
			`storage volume for image "%s" on storage pool "%s":
			%s`, fingerprint, s.pool.Name, err)
		return err
	}
	logger.Debugf(`Deleted database entry for RBD storage volume for `+
		`image "%s" on storage pool "%s"`, fingerprint, s.pool.Name)

	imageMntPoint := getImageMountPoint(s.pool.Name, fingerprint)
	if shared.PathExists(imageMntPoint) {
		err := os.Remove(imageMntPoint)
		if err != nil {
			logger.Errorf(`Failed to delete image mountpoint "%s" `+
				`for RBD storage volume for image "%s" on `+
				`storage pool "%s": %s`, imageMntPoint,
				fingerprint, s.pool.Name, err)
			return err
		}
		logger.Debugf(`Deleted image mountpoint "%s" for RBD storage `+
			`volume for image "%s" on storage pool "%s"`,
			imageMntPoint, fingerprint, s.pool.Name)
	}

	logger.Debugf(`Deleted RBD storage volume for image "%s" on storage `+
		`pool "%s"`, fingerprint, s.pool.Name)
	return nil
}

func (s *storageCeph) ImageMount(fingerprint string) (bool, error) {
	logger.Debugf("Mounting RBD storage volume for image \"%s\" on storage pool \"%s\".", fingerprint, s.pool.Name)

	imageMntPoint := getImageMountPoint(s.pool.Name, fingerprint)
	if shared.IsMountPoint(imageMntPoint) {
		return false, nil
	}

	RBDFilesystem := s.getRBDFilesystem()
	RBDMountOptions := s.getRBDMountOptions()
	mountFlags, mountOptions := apolloResolveMountoptions(RBDMountOptions)
	RBDDevPath, ret := getRBDMappedDevPath(s.ClusterName, s.OSDPoolName,
		storagePoolVolumeTypeNameImage, fingerprint, true, s.UserName)
	errMsg := fmt.Sprintf("Failed to mount RBD device %s onto %s",
		RBDDevPath, imageMntPoint)
	if ret < 0 {
		logger.Errorf(errMsg)
		return false, fmt.Errorf(errMsg)
	}

	err := tryMount(RBDDevPath, imageMntPoint, RBDFilesystem, mountFlags, mountOptions)
	if err != nil || ret < 0 {
		logger.Errorf("%s: %s", errMsg, err)
		return false, err
	}

	logger.Debugf("Mounted RBD storage volume for image \"%s\" on storage pool \"%s\".", fingerprint, s.pool.Name)
	return true, nil
}

func (s *storageCeph) ImageUmount(fingerprint string) (bool, error) {
	logger.Debugf("Unmounting RBD storage volume for image \"%s\" on storage pool \"%s\".", fingerprint, s.pool.Name)

	imageMntPoint := getImageMountPoint(s.pool.Name, fingerprint)
	if !shared.IsMountPoint(imageMntPoint) {
		return false, nil
	}

	err := tryUnmount(imageMntPoint, 0)
	if err != nil {
		return false, err
	}

	logger.Debugf("Unmounted RBD storage volume for image \"%s\" on storage pool \"%s\".", fingerprint, s.pool.Name)
	return true, nil
}

func (s *storageCeph) StorageEntitySetQuota(volumeType int, size int64, data interface{}) error {
	return fmt.Errorf("RBD storage volume quota are not supported")
}
