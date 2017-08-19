package main

import (
	"fmt"
	"os"
	"strconv"

	"gopkg.in/mercury/go-mercury.v2"
)

/*
 * Similar to forkstart, this is called when apollo is invoked as:
 *
 *    apollo forkmigrate <container> <mercurypath> <path_to_config> <path_to_criu_images> <preserves_inodes>
 *
 * libmercury's restore() sets up the processes in such a way that the monitor ends
 * up being a child of the process that calls it, in our case apollo. However, we
 * really want the monitor to be daemonized, so we fork again. Additionally, we
 * want to fork for the same reasons we do forkstart (i.e. reduced memory
 * footprint when we fork tasks that will never free golang's memory, etc.)
 */
func cmdForkMigrate(args []string) error {
	if len(args) != 6 {
		return fmt.Errorf("Bad arguments %q", args)
	}

	name := args[1]
	mercurypath := args[2]
	configPath := args[3]
	imagesDir := args[4]
	preservesInodes, err := strconv.ParseBool(args[5])

	c, err := mercury.NewContainer(name, mercurypath)
	if err != nil {
		return err
	}

	if err := c.LoadConfigFile(configPath); err != nil {
		return err
	}

	/* see https://github.com/golang/go/issues/13155, startContainer, and dc3a229 */
	os.Stdin.Close()
	os.Stdout.Close()
	os.Stderr.Close()

	return c.Migrate(mercury.MIGRATE_RESTORE, mercury.MigrateOptions{
		Directory:       imagesDir,
		Verbose:         true,
		PreservesInodes: preservesInodes,
	})
}
