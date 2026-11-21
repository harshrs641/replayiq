package masking

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/harshrs641/replayiq/internal/models"
)

func TestRedactCardsUsesLuhn(t *testing.T) {
	for in, want := range map[string]string{
		"card 4242 4242 4242 4242 ok": "card [redacted] ok",
		"4111-1111-1111-1111":          "[redacted]",
		"order 1234567890123 shipped":  "order 1234567890123 shipped", // not Luhn-valid
		"short 4242":                   "short 4242",
	} {
		if got := RedactCards(in); got != want {
			t.Errorf("%q: %q want %q", in, got, want)
		}
	}
}

func TestRedactBodyJSONFormAndURL(t *testing.T) {
	body := `{"user":"jane","password":"hunter2","card":{"number":"4242424242424242","cvv":"123"},"items":[{"token":"abc"}]}`
	out := RedactBody(body, "application/json")
	for _, leak := range []string{"hunter2", "4242424242424242", `"123"`, "abc"} {
		if strings.Contains(out, leak) {
			t.Fatalf("leaked %s: %s", leak, out)
		}
	}
	if !strings.Contains(out, `"user":"jane"`) {
		t.Fatalf("over-redacted: %s", out)
	}
	if got := RedactBody("user=jane&password=x&pin=1234", "application/x-www-form-urlencoded"); strings.Contains(got, "password=x") || strings.Contains(got, "pin=1234") || !strings.Contains(got, "user=jane") {
		t.Fatalf("form: %s", got)
	}
	if got := RedactURL("https://api.test/pay?order=42&access_token=SECRET&card=4242424242424242"); strings.Contains(got, "SECRET") || strings.Contains(got, "4242424242424242") || !strings.Contains(got, "order=42") {
		t.Fatalf("url: %s", got)
	}
}

func networkEvent(t *testing.T, js string) models.RRWebEvent {
	t.Helper()
	var e models.RRWebEvent
	if err := json.Unmarshal([]byte(js), &e); err != nil {
		t.Fatal(err)
	}
	return e
}

func TestApplyAlwaysAndScrubOnNetworkEvents(t *testing.T) {
	e := networkEvent(t, `{"type":5,"subtype":"network","timestamp":1,"method":"POST","url":"https://api.test/login?token=T",
	  "request":{"headers":{"Authorization":"Bearer SECRET","content-type":"application/json","x-user":"jane@acme.com"},
	             "body":"{\"email\":\"jane@acme.com\",\"password\":\"hunter2\"}"},
	  "response":{"headers":{"set-cookie":"sid=1"},"body":"{\"ok\":true}"}}`)
	ApplyAlways(&e)
	raw, _ := json.Marshal(e)
	s := string(raw)
	for _, leak := range []string{"SECRET", "hunter2", "sid=1", "token=T"} {
		if strings.Contains(s, leak) {
			t.Fatalf("raw copy leaked %s: %s", leak, s)
		}
	}
	if !strings.Contains(s, "jane@acme.com") {
		t.Fatal("raw copy keeps non-secret PII (emails) as recorded")
	}
	ScrubNetworkConsole(&e, DefaultConfig(nil))
	raw, _ = json.Marshal(e)
	if strings.Contains(string(raw), "jane@acme.com") {
		t.Fatalf("masked copy must scrub PII: %s", raw)
	}
}

func TestApplyAlwaysOnConsoleArgs(t *testing.T) {
	e := networkEvent(t, `{"type":5,"subtype":"console","timestamp":1,"level":"info","message":"paid with 4242 4242 4242 4242",
	  "args":[{"card_number":"4242424242424242","note":"hi jane@acme.com"}]}`)
	ApplyAlways(&e)
	raw, _ := json.Marshal(e)
	if strings.Contains(string(raw), "4242") {
		t.Fatalf("card leaked: %s", raw)
	}
	ScrubNetworkConsole(&e, DefaultConfig(nil))
	raw, _ = json.Marshal(e)
	if strings.Contains(string(raw), "jane@acme.com") {
		t.Fatalf("masked args keep PII: %s", raw)
	}
}
