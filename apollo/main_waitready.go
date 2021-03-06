package main

import (
	"fmt"
	"time"

	"github.com/AriseBank/apollo-controller/client"
)

func cmdWaitReady() error {
	var timeout int

	if *argTimeout == -1 {
		timeout = 15
	} else {
		timeout = *argTimeout
	}

	finger := make(chan error, 1)
	go func() {
		for {
			c, err := apollo.ConnectAPOLLOUnix("", nil)
			if err != nil {
				time.Sleep(500 * time.Millisecond)
				continue
			}

			_, _, err = c.RawQuery("GET", "/internal/ready", nil, "")
			if err != nil {
				time.Sleep(500 * time.Millisecond)
				continue
			}

			finger <- nil
			return
		}
	}()

	select {
	case <-finger:
		break
	case <-time.After(time.Second * time.Duration(timeout)):
		return fmt.Errorf("APOLLO still not running after %ds timeout.", timeout)
	}

	return nil
}
