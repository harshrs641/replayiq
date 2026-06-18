package api

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/harshrs641/replayiq/internal/jira"
	"github.com/harshrs641/replayiq/internal/models"
)

// POST /api/v1/jira/issues — push AI issue to Jira
func (r *router) handleJiraCreateIssue(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var jiraReq models.JiraIssueRequest
	if err := json.NewDecoder(req.Body).Decode(&jiraReq); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body")
		return
	}

	result, err := r.jiraClient.CreateIssue(req.Context(), &jiraReq)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	// Update the issue record with Jira key
	r.cfg.DB.UpdateIssueJira(req.Context(), jiraReq.IssueID, result.Key, result.URL)

	writeJSON(w, http.StatusCreated, result)
}

// POST /api/v1/jira/webhook — Jira calls this on issue update
func (r *router) handleJiraWebhook(w http.ResponseWriter, req *http.Request) {
	var event jira.WebhookEvent
	json.NewDecoder(req.Body).Decode(&event)
	slog.Info("jira webhook", "event", event.WebhookEvent, "key", event.Issue.Key, "status", event.Issue.Fields.Status.Name)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
