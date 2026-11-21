package masking

// Always-masked data (Recording API v1.2 §4): secrets and card data are
// redacted in every stored copy, raw included, whatever the SDK did. SDKs
// apply the same rules on the device; this is the server's second line.
//
//   - values of auth/cookie headers
//   - card numbers (13–19 digits passing the Luhn check)
//   - values of sensitive keys (password, token, cvv, …) in JSON bodies,
//     form bodies, query strings and console arguments

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strings"

	"github.com/harshrs641/replayiq/internal/models"
)

// Redacted replaces an always-masked value.
const Redacted = "[redacted]"

var secretHeaders = map[string]bool{
	"authorization": true, "proxy-authorization": true, "cookie": true, "set-cookie": true,
	"x-api-key": true, "x-auth-token": true, "x-csrf-token": true, "x-xsrf-token": true,
}

var sensitiveKeys = map[string]bool{
	"password": true, "passwd": true, "pwd": true, "secret": true, "clientsecret": true,
	"token": true, "accesstoken": true, "refreshtoken": true, "idtoken": true, "authtoken": true,
	"apikey": true, "privatekey": true, "otp": true, "pin": true,
	"cvv": true, "cvc": true, "cvv2": true, "cardnumber": true, "pan": true, "securitycode": true,
	"ssn": true,
}

// IsSensitiveKey reports whether a JSON/form/query key holds a secret.
func IsSensitiveKey(k string) bool {
	n := strings.ToLower(strings.NewReplacer("_", "", "-", "", " ", "").Replace(k))
	return sensitiveKeys[n]
}

// IsSecretHeader reports whether a header's value is always redacted.
func IsSecretHeader(name string) bool { return secretHeaders[strings.ToLower(name)] }

var cardRe = regexp.MustCompile(`\b\d(?:[ -]?\d){12,18}\b`)

// RedactCards replaces Luhn-valid card numbers in s.
func RedactCards(s string) string {
	if len(s) < 13 {
		return s
	}
	return cardRe.ReplaceAllStringFunc(s, func(m string) string {
		digits := make([]byte, 0, 19)
		for i := 0; i < len(m); i++ {
			if m[i] >= '0' && m[i] <= '9' {
				digits = append(digits, m[i])
			}
		}
		if len(digits) < 13 || len(digits) > 19 || !luhn(digits) {
			return m
		}
		return Redacted
	})
}

func luhn(d []byte) bool {
	sum := 0
	double := false
	for i := len(d) - 1; i >= 0; i-- {
		n := int(d[i] - '0')
		if double {
			n *= 2
			if n > 9 {
				n -= 9
			}
		}
		sum += n
		double = !double
	}
	return sum%10 == 0
}

// RedactURL masks sensitive query values and card numbers in a URL.
func RedactURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.RawQuery == "" {
		return RedactCards(raw)
	}
	q := u.Query()
	changed := false
	for k, vs := range q {
		for i, v := range vs {
			nv := v
			if IsSensitiveKey(k) {
				nv = Redacted
			} else {
				nv = RedactCards(v)
			}
			if nv != v {
				vs[i] = nv
				changed = true
			}
		}
	}
	if changed {
		u.RawQuery = q.Encode()
	}
	return RedactCards(u.String())
}

// RedactBody masks always-masked values in a request/response body:
// sensitive keys in JSON and form bodies, card numbers anywhere.
func RedactBody(body, contentType string) string {
	if body == "" {
		return body
	}
	trimmed := strings.TrimSpace(body)
	if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		var v any
		if json.Unmarshal([]byte(trimmed), &v) == nil {
			if out, err := json.Marshal(redactJSON(v, func(s string) string { return RedactCards(s) })); err == nil {
				return string(out)
			}
		}
	}
	if strings.Contains(contentType, "x-www-form-urlencoded") || (!strings.ContainsAny(trimmed, " \n{<") && strings.Contains(trimmed, "=")) {
		if q, err := url.ParseQuery(trimmed); err == nil && len(q) > 0 {
			for k, vs := range q {
				for i := range vs {
					if IsSensitiveKey(k) {
						vs[i] = Redacted
					} else {
						vs[i] = RedactCards(vs[i])
					}
				}
			}
			return q.Encode()
		}
	}
	return RedactCards(body)
}

// redactJSON masks sensitive keys and applies str to every other string.
func redactJSON(v any, str func(string) string) any {
	switch t := v.(type) {
	case map[string]any:
		for k, val := range t {
			if IsSensitiveKey(k) {
				if val != nil {
					t[k] = Redacted
				}
				continue
			}
			t[k] = redactJSON(val, str)
		}
		return t
	case []any:
		for i := range t {
			t[i] = redactJSON(t[i], str)
		}
		return t
	case string:
		return str(t)
	}
	return v
}

// ApplyAlways enforces the always-masked rules on one event (any copy).
func ApplyAlways(e *models.RRWebEvent) {
	if e.Type != 5 {
		return
	}
	switch e.Subtype {
	case "network":
		e.URL = RedactURL(e.URL)
		e.Error = RedactCards(e.Error)
		editExtra(e, func(name string, v any) any { return redactHTTP(name, v, nil) })
	case "console", "js_error":
		e.Message = RedactCards(e.Message)
		e.Stack = RedactCards(e.Stack)
		editExtra(e, func(name string, v any) any {
			if name == "args" {
				return redactJSON(v, RedactCards)
			}
			return v
		})
	default:
		e.Message = RedactCards(e.Message)
	}
}

// ScrubNetworkConsole applies the PII rules (emails, phones, …) on top of
// ApplyAlways, for masked copies: URL, header values, bodies, console args.
func ScrubNetworkConsole(e *models.RRWebEvent, cfg Config) {
	if e.Type != 5 {
		return
	}
	switch e.Subtype {
	case "network":
		editExtra(e, func(name string, v any) any {
			return redactHTTP(name, v, func(s string) string { return maskText(s, cfg) })
		})
	case "console":
		editExtra(e, func(name string, v any) any {
			if name == "args" {
				return redactJSON(v, func(s string) string { return maskText(s, cfg) })
			}
			return v
		})
	}
}

// redactHTTP handles the request/response objects of a network event.
// extra, when set, is applied to header values and bodies after the
// always-masked rules.
func redactHTTP(name string, v any, extra func(string) string) any {
	if name != "request" && name != "response" {
		return v
	}
	m, ok := v.(map[string]any)
	if !ok {
		return v
	}
	if h, ok := m["headers"].(map[string]any); ok {
		for k, hv := range h {
			s, isStr := hv.(string)
			switch {
			case IsSecretHeader(k):
				h[k] = Redacted
			case isStr && extra != nil:
				h[k] = extra(RedactCards(s))
			case isStr:
				h[k] = RedactCards(s)
			}
		}
	}
	if b, ok := m["body"].(string); ok {
		ct, _ := m["content_type"].(string)
		if ct == "" {
			if h, ok := m["headers"].(map[string]any); ok {
				ct, _ = h["content-type"].(string)
			}
		}
		b = RedactBody(b, ct)
		if extra != nil {
			b = extra(b)
		}
		m["body"] = b
	}
	return m
}

// editExtra decodes, edits and re-encodes the event's extra fields.
func editExtra(e *models.RRWebEvent, f func(name string, v any) any) {
	if len(e.Extra) == 0 {
		return
	}
	// A new map: copies of a batch (raw and masked) share event values.
	extra := make(map[string]json.RawMessage, len(e.Extra))
	for k, v := range e.Extra {
		extra[k] = v
	}
	e.Extra = extra
	for name, raw := range e.Extra {
		var v any
		if json.Unmarshal(raw, &v) != nil {
			continue
		}
		nv := f(name, v)
		if out, err := json.Marshal(nv); err == nil {
			e.Extra[name] = out
		}
	}
}
