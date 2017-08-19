package main

import (
	"fmt"
	"os"
	"sort"

	"github.com/AriseBank/apollo-controller/mercury/config"
	"github.com/AriseBank/apollo-controller/shared/gnuflag"
	"github.com/AriseBank/apollo-controller/shared/i18n"
)

type helpCmd struct {
	showAll bool
}

func (c *helpCmd) showByDefault() bool {
	return true
}

func (c *helpCmd) usage() string {
	return i18n.G(
		`Usage: mercury help [--all]

Help page for the APOLLO client.`)
}

func (c *helpCmd) flags() {
	gnuflag.BoolVar(&c.showAll, "all", false, i18n.G("Show all commands (not just interesting ones)"))
}

func (c *helpCmd) run(conf *config.Config, args []string) error {
	if len(args) > 0 {
		for _, name := range args {
			cmd, ok := commands[name]
			if !ok {
				fmt.Fprintf(os.Stderr, i18n.G("error: unknown command: %s")+"\n", name)
			} else {
				fmt.Fprintf(os.Stdout, cmd.usage()+"\n")
			}
		}
		return nil
	}

	fmt.Println(i18n.G("Usage: mercury <command> [options]"))
	fmt.Println()
	fmt.Println(i18n.G(`This is the APOLLO command line client.

All of APOLLO's features can be driven through the various commands below.
For help with any of those, simply call them with --help.`))
	fmt.Println()

	fmt.Println(i18n.G("Commands:"))
	var names []string
	for name := range commands {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if name == "help" {
			continue
		}

		cmd := commands[name]
		if c.showAll || cmd.showByDefault() {
			fmt.Printf("  %-16s %s\n", name, summaryLine(cmd.usage()))
		}
	}

	fmt.Println()
	fmt.Println(i18n.G("Options:"))
	fmt.Println("  --all            " + i18n.G("Print less common commands"))
	fmt.Println("  --debug          " + i18n.G("Print debug information"))
	fmt.Println("  --verbose        " + i18n.G("Print verbose information"))
	fmt.Println("  --version        " + i18n.G("Show client version"))
	fmt.Println()
	fmt.Println(i18n.G("Environment:"))
	fmt.Println("  APOLLO_CONF         " + i18n.G("Path to an alternate client configuration directory"))
	fmt.Println("  APOLLO_DIR          " + i18n.G("Path to an alternate server directory"))

	return nil
}
