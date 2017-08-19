package main

import (
	"fmt"
	"github.com/AriseBank/apollo-controller/client"
)

func cmdImport(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("please specify a container to import")
	}
	name := args[1]
	req := map[string]interface{}{
		"name":  name,
		"force": *argForce,
	}

	c, err := apollo.ConnectAPOLLOUnix("", nil)
	if err != nil {
		return err
	}

	_, _, err = c.RawQuery("POST", "/internal/containers", req, "")
	if err != nil {
		return err
	}

	return nil
}
