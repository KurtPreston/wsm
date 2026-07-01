package macos

import (
	"testing"

	"github.com/KurtPreston/wsm/libs/webserver"
)

func TestParseCursorTitle(t *testing.T) {
	cases := []struct {
		title, leaf, host string
	}{
		{"my-feature [SSH: devbox] - Cursor", "my-feature", "devbox"},
		{"file.ts - my-feature - Cursor", "my-feature", ""},
		{"proj - Cursor", "proj", ""},
		{"Cursor", "", ""},
		{"", "", ""},
	}
	for _, c := range cases {
		leaf, host := parseCursorTitle(c.title)
		if leaf != c.leaf || host != c.host {
			t.Errorf("parseCursorTitle(%q) = (%q,%q), want (%q,%q)", c.title, leaf, host, c.leaf, c.host)
		}
	}
}

func TestLaunchArgsSubstitutesURI(t *testing.T) {
	got := launchArgs(webserver.IDEProfile{LaunchArgs: []string{"--new-window", "--folder-uri", "{uri}"}}, "file:///x")
	want := []string{"--new-window", "--folder-uri", "file:///x"}
	if len(got) != len(want) {
		t.Fatalf("args = %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("args = %v, want %v", got, want)
		}
	}
}
