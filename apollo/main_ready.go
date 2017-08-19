package main

import (
	"github.com/AriseBank/apollo-controller/client"
)

func cmdReady() error {
	c, err := apollo.ConnectAPOLLOUnix("", nil)
	if err != nil {
		return err
	}

	_, _, err = c.RawQuery("PUT", "/internal/ready", nil, "")
	if err != nil {
		return err
	}

	return nil
}
