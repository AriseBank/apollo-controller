package main

import (
	"fmt"
	"os"

	"github.com/AriseBank/apollo-controller/client"
	"github.com/AriseBank/apollo-controller/apollo/db"
	"github.com/AriseBank/apollo-controller/shared"
	"github.com/AriseBank/apollo-controller/shared/logger"
)

func cmdActivateIfNeeded() error {
	// Only root should run this
	if os.Geteuid() != 0 {
		return fmt.Errorf("This must be run as root")
	}

	// Don't start a full daemon, we just need DB access
	d := &Daemon{
		mercurypath: shared.VarPath("containers"),
	}

	if !shared.PathExists(shared.VarPath("apollo.db")) {
		logger.Debugf("No DB, so no need to start the daemon now.")
		return nil
	}

	err := initializeDbObject(d, shared.VarPath("apollo.db"))
	if err != nil {
		return err
	}

	/* Load all config values from the database */
	err = daemonConfigInit(d.db)
	if err != nil {
		return err
	}

	// Look for network socket
	value := daemonConfig["core.https_address"].Get()
	if value != "" {
		logger.Debugf("Daemon has core.https_address set, activating...")
		_, err := apollo.ConnectAPOLLOUnix("", nil)
		return err
	}

	// Load the idmap for unprivileged containers
	d.IdmapSet, err = shared.DefaultIdmapSet()
	if err != nil {
		return err
	}

	// Look for auto-started or previously started containers
	result, err := db.ContainersList(d.db, db.CTypeRegular)
	if err != nil {
		return err
	}

	for _, name := range result {
		c, err := containerLoadByName(d, name)
		if err != nil {
			return err
		}

		config := c.ExpandedConfig()
		lastState := config["volatile.last_state.power"]
		autoStart := config["boot.autostart"]

		if c.IsRunning() {
			logger.Debugf("Daemon has running containers, activating...")
			_, err := apollo.ConnectAPOLLOUnix("", nil)
			return err
		}

		if lastState == "RUNNING" || lastState == "Running" || shared.IsTrue(autoStart) {
			logger.Debugf("Daemon has auto-started containers, activating...")
			_, err := apollo.ConnectAPOLLOUnix("", nil)
			return err
		}
	}

	logger.Debugf("No need to start the daemon now.")
	return nil
}
