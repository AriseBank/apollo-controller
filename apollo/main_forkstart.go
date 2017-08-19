package main

import (
	"fmt"
	"os"
	"syscall"

	"gopkg.in/mercury/go-mercury.v2"

	"github.com/AriseBank/apollo-controller/shared"
)

/*
 * This is called by apollo when called as "apollo forkstart <container>"
 * 'forkstart' is used instead of just 'start' in the hopes that people
 * do not accidentally type 'apollo start' instead of 'mercury start'
 */
func cmdForkStart(args []string) error {
	if len(args) != 4 {
		return fmt.Errorf("Bad arguments: %q", args)
	}

	name := args[1]
	mercurypath := args[2]
	configPath := args[3]

	c, err := mercury.NewContainer(name, mercurypath)
	if err != nil {
		return fmt.Errorf("Error initializing container for start: %q", err)
	}

	err = c.LoadConfigFile(configPath)
	if err != nil {
		return fmt.Errorf("Error opening startup config file: %q", err)
	}

	/* due to https://github.com/golang/go/issues/13155 and the
	 * CollectOutput call we make for the forkstart process, we need to
	 * close our stdin/stdout/stderr here. Collecting some of the logs is
	 * better than collecting no logs, though.
	 */
	os.Stdin.Close()
	os.Stderr.Close()
	os.Stdout.Close()

	// Redirect stdout and stderr to a log file
	logPath := shared.LogPath(name, "forkstart.log")
	if shared.PathExists(logPath) {
		os.Remove(logPath)
	}

	logFile, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_SYNC, 0644)
	if err == nil {
		syscall.Dup3(int(logFile.Fd()), 1, 0)
		syscall.Dup3(int(logFile.Fd()), 2, 0)
	}

	return c.Start()
}
