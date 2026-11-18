package masking

import (
	"strings"
	"testing"

	"github.com/harshrs641/replayiq/internal/models"
)

func TestMaskBatchRedactsErrorDetails(t *testing.T) {
	batch := &models.EventBatch{SessionID: "s", Events: []models.RRWebEvent{{
		Type:     5,
		Subtype:  "js_error",
		Message:  "failed for ada@example.com",
		Filename: "https://app.test/u/ada@example.com/app.js",
		Stack:    "Error: card 4111 1111 1111 1111 rejected\n    at pay (app.js:1:2)",
		Error:    "lookup failed for ada@example.com",
		Lineno:   12,
	}}}
	got := MaskBatch(NewTracker(), batch, DefaultConfig(nil)).Events[0]
	for name, v := range map[string]string{"message": got.Message, "filename": got.Filename, "stack": got.Stack, "error": got.Error} {
		if strings.Contains(v, "ada@example.com") || strings.Contains(v, "4111 1111 1111 1111") {
			t.Errorf("%s not masked: %q", name, v)
		}
	}
	if got.Lineno != 12 || !strings.Contains(got.Stack, "at pay (app.js:1:2)") {
		t.Errorf("non-PII details must survive masking: %+v", got)
	}
	if batch.Events[0].Stack == got.Stack {
		t.Error("MaskBatch must not modify the raw batch")
	}
}

func TestMaskTextFieldsLeavesDataAlone(t *testing.T) {
	img := "data:image/jpeg;base64,ada@example.com" // would match the email rule
	batch := &models.EventBatch{SessionID: "s", DeviceMasked: true, Events: []models.RRWebEvent{
		{Type: 3, Data: map[string]any{"src": img}},
		{Type: 5, Subtype: "console", Message: "login failed for ada@example.com"},
	}}
	got := MaskTextFields(batch, DefaultConfig(nil))
	if got.Events[0].Data["src"] != img {
		t.Error("Data (screenshots) must be left as is")
	}
	if strings.Contains(got.Events[1].Message, "ada@example.com") {
		t.Errorf("message not masked: %q", got.Events[1].Message)
	}
	if !got.DeviceMasked || batch.Events[1].Message != "login failed for ada@example.com" {
		t.Error("must keep the flag and not modify the input")
	}
}
