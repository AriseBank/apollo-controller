package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/AriseBank/apollo-controller/mercury/config"
	"github.com/AriseBank/apollo-controller/shared/i18n"
)

type manpageCmd struct{}

func (c *manpageCmd) showByDefault() bool {
	return false
}

func (c *manpageCmd) usage() string {
	return i18n.G(
		`Usage: mercury manpage <directory>

Generate all the APOLLO manpages.`)
}

func (c *manpageCmd) flags() {
}

func (c *manpageCmd) run(conf *config.Config, args []string) error {
	if len(args) != 1 {
		return errArgs
	}

	_, err := exec.LookPath("help2man")
	if err != nil {
		return fmt.Errorf(i18n.G("Unable to find help2man."))
	}

	help2man := func(command string, title string, path string) error {
		target, err := os.Create(path)
		if err != nil {
			return err
		}
		defer target.Close()

		cmd := exec.Command("help2man", command, "-n", title, "--no-info")
		cmd.Stdout = target

		return cmd.Run()
	}

	// Generate the main manpage
	err = help2man(fmt.Sprintf("%s --all", execName), "APOLLO - client", filepath.Join(args[0], fmt.Sprintf("mercury.1")))
	if err != nil {
		return fmt.Errorf(i18n.G("Failed to generate 'mercury.1': %v"), err)
	}

	// Generate the pages for the subcommands
	for k, cmd := range commands {
		err := help2man(fmt.Sprintf("%s %s", execName, k), summaryLine(cmd.usage()), filepath.Join(args[0], fmt.Sprintf("mercury.%s.1", k)))
		if err != nil {
			return fmt.Errorf(i18n.G("Failed to generate 'mercury.%s.1': %v"), k, err)
		}
	}

	return nil
}
