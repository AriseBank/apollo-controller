package main

import (
	"github.com/AriseBank/apollo-controller/mercury/config"
	"github.com/AriseBank/apollo-controller/shared/i18n"
)

type fingerCmd struct{}

func (c *fingerCmd) showByDefault() bool {
	return false
}

func (c *fingerCmd) usage() string {
	return i18n.G(
		`Usage: mercury finger [<remote>:]

Check if the APOLLO server is alive.`)
}

func (c *fingerCmd) flags() {}

func (c *fingerCmd) run(conf *config.Config, args []string) error {
	if len(args) > 1 {
		return errArgs
	}

	// Parse the remote
	remote := conf.DefaultRemote
	if len(args) > 0 {
		var err error
		remote, _, err = conf.ParseRemote(args[0])
		if err != nil {
			return err
		}
	}

	// Attempt to connect
	_, err := conf.GetContainerServer(remote)
	if err != nil {
		return err
	}

	return nil
}
