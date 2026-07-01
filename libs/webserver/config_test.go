package webserver

import "testing"

func TestValidateRequiresToken(t *testing.T) {
	c := Default()
	if err := c.Validate(); err == nil {
		t.Fatal("expected error when token is empty")
	}
}

func TestValidateLocalRejectsNonLoopback(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.Bind = "0.0.0.0"
	if err := c.Validate(); err == nil {
		t.Fatal("expected local mode to reject a non-loopback bind")
	}
}

func TestValidateNetworkRequiresTLS(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.Mode = ModeNetwork
	c.Bind = "0.0.0.0"
	if err := c.Validate(); err == nil {
		t.Fatal("expected network mode to require TLS")
	}
	c.TLS = TLSConfig{Cert: "/tmp/c.pem", Key: "/tmp/k.pem"}
	if err := c.Validate(); err != nil {
		t.Fatalf("network mode with TLS should validate: %v", err)
	}
}

func TestValidateUnknownIDE(t *testing.T) {
	c := Default()
	c.Token = "x"
	c.IDE = "emacs"
	if err := c.Validate(); err == nil {
		t.Fatal("expected error for IDE with no profile")
	}
}

func TestIsLoopback(t *testing.T) {
	cases := map[string]bool{
		"":          true,
		"localhost": true,
		"127.0.0.1": true,
		"127.0.1.5": true,
		"::1":       true,
		"0.0.0.0":   false,
		"10.0.0.5":  false,
	}
	for bind, want := range cases {
		if got := isLoopback(bind); got != want {
			t.Errorf("isLoopback(%q) = %v, want %v", bind, got, want)
		}
	}
}

func TestUnmarshalJSONC(t *testing.T) {
	data := []byte(`{
		// line comment
		"mode": "local",
		"port": 39788, /* block */
		"ide": "cursor",
		"profiles": {
			"cursor": {
				"process": "Cursor",
				"remoteUri": "vscode-remote://ssh-remote+{host}{path}", // keep the // in the URI
			},
		},
	}`)
	var c Config
	if err := unmarshalJSONC(data, &c); err != nil {
		t.Fatalf("unmarshalJSONC: %v", err)
	}
	if c.Mode != ModeLocal || c.Port != 39788 {
		t.Fatalf("unexpected parse: %+v", c)
	}
	if got := c.Profiles["cursor"].RemoteURI; got != "vscode-remote://ssh-remote+{host}{path}" {
		t.Fatalf("URI mangled by comment stripper: %q", got)
	}
}

func TestActiveProfile(t *testing.T) {
	c := Default()
	p, ok := c.ActiveProfile()
	if !ok || p.Process != "Cursor" {
		t.Fatalf("active profile = %+v ok=%v", p, ok)
	}
}
