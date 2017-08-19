package main

import (
	"fmt"

	"github.com/AriseBank/apollo-controller/mercury/config"
	"github.com/AriseBank/apollo-controller/shared"
	"github.com/AriseBank/apollo-controller/shared/api"
	"github.com/AriseBank/apollo-controller/shared/gnuflag"
	"github.com/AriseBank/apollo-controller/shared/i18n"
)

type snapshotCmd struct {
	stateful bool
}

func (c *snapshotCmd) showByDefault() bool {
	return true
}

func (c *snapshotCmd) usage() string {
	return i18n.G(
		`Usage: mercury snapshot [<remote>:]<container> <snapshot name> [--stateful]

Create container snapshots.

When --stateful is used, APOLLO attempts to checkpoint the container's
running state, including process memory state, TCP connections, ...

*Examples*
mercury snapshot u1 snap0
    Create a snapshot of "u1" called "snap0".`)
}

func (c *snapshotCmd) flags() {
	gnuflag.BoolVar(&c.stateful, "stateful", false, i18n.G("Whether or not to snapshot the container's running state"))
}

func (c *snapshotCmd) run(conf *config.Config, args []string) error {
	if len(args) < 1 {
		return errArgs
	}

	var snapname string
	if len(args) < 2 {
		snapname = ""
	} else {
		snapname = args[1]
	}

	// we don't allow '/' in snapshot names
	if shared.IsSnapshot(snapname) {
		return fmt.Errorf(i18n.G("'/' not allowed in snapshot name"))
	}

	remote, name, err := conf.ParseRemote(args[0])
	if err != nil {
		return err
	}

	d, err := conf.GetContainerServer(remote)
	if err != nil {
		return err
	}

	req := api.ContainerSnapshotsPost{
		Name:     snapname,
		Stateful: c.stateful,
	}

	op, err := d.CreateContainerSnapshot(name, req)
	if err != nil {
		return err
	}

	return op.Wait()
}
