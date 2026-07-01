// Command wsm-macos is the macOS workspace-management daemon (wsmd).
//
// It serves the wsm workspace-management API and drives Cursor/VSCode windows
// via AppleScript (osascript). The HTTP layer, auth, and mode enforcement are
// provided by libs/webserver; this binary supplies the macOS WindowManager.
package main

import (
	"flag"
	"log"

	"github.com/KurtPreston/wsm/apps/wsm-macos/macos"
	"github.com/KurtPreston/wsm/libs/webserver"
)

func main() {
	configPath := flag.String("config", "", "path to wsm config (JSONC); empty = discovery chain")
	port := flag.Int("port", 0, "override the configured listen port")
	flag.Parse()

	cfg, err := webserver.Load(*configPath)
	if err != nil {
		log.Fatalf("wsm-macos: %v", err)
	}
	if *port != 0 {
		cfg.Port = *port
	}

	if err := webserver.Serve(cfg, macos.New()); err != nil {
		log.Fatalf("wsm-macos: %v", err)
	}
}
