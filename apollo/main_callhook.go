package main

import (
	"fmt"
	"os"
	"time"

	"github.com/AriseBank/apollo-controller/client"
)

func cmdCallHook(args []string) error {
	// Parse the arguments
	if len(args) < 4 {
		return fmt.Errorf("Invalid arguments")
	}

	path := args[1]
	id := args[2]
	state := args[3]
	target := ""

	// Connect to APOLLO
	c, err := apollo.ConnectAPOLLOUnix(fmt.Sprintf("%s/unix.socket", path), nil)
	if err != nil {
		return err
	}

	// Prepare the request URL
	url := fmt.Sprintf("/internal/containers/%s/on%s", id, state)
	if state == "stop" {
		target = os.Getenv("MERCURY_TARGET")
		if target == "" {
			target = "unknown"
		}
		url = fmt.Sprintf("%s?target=%s", url, target)
	}

	// Setup the request
	hook := make(chan error, 1)
	go func() {
		_, _, err := c.RawQuery("GET", url, nil, "")
		if err != nil {
			hook <- err
			return
		}

		hook <- nil
	}()

	// Handle the timeout
	select {
	case err := <-hook:
		if err != nil {
			return err
		}
		break
	case <-time.After(30 * time.Second):
		return fmt.Errorf("Hook didn't finish within 30s")
	}

	if target == "reboot" {
		return fmt.Errorf("Reboot must be handled by APOLLO.")
	}

	return nil
}
