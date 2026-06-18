package jira

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/harshrs641/replayiq/internal/models"
)

type Client struct {
	baseURL    string
	authHeader string
	projectKey string
	http       *http.Client
}

type Config struct {
	BaseURL    string
	Email      string
	APIToken   string
	ProjectKey string
}

func NewClient(cfg Config) *Client {
	auth := base64.StdEncoding.EncodeToString([]byte(cfg.Email + ":" + cfg.APIToken))
	return &Client{
		baseURL:    cfg.BaseURL,
		authHeader: "Basic " + auth,
		projectKey: cfg.ProjectKey,
		http:       &http.Client{Timeout: 15 * time.Second},
	}
}

// ─── Jira API types ───────────────────────────────────────────────────────────

type createIssuePayload struct {
	Fields struct {
		Project     struct{ Key string } `json:"project"`
		Summary     string               `json:"summary"`
		Description struct {
			Type    string `json:"type"`
			Version int    `json:"version"`
			Content []struct {
				Type    string `json:"type"`
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			} `json:"content"`
		} `json:"description"`
		IssueType struct{ Name string } `json:"issuetype"`
		Priority  struct{ Name string } `json:"priority"`
		Labels    []string              `json:"labels"`
	} `json:"fields"`
}

type createIssueResponse struct {
	ID   string `json:"id"`
	Key  string `json:"key"`
	Self string `json:"self"`
}

func (c *Client) CreateIssue(ctx context.Context, req *models.JiraIssueRequest) (*models.JiraIssueResponse, error) {
	if c.baseURL == "" {
		return nil, fmt.Errorf("jira not configured")
	}

	var payload createIssuePayload
	payload.Fields.Project.Key = c.projectKey
	payload.Fields.Summary = req.Summary
	payload.Fields.IssueType.Name = req.IssueType
	payload.Fields.Priority.Name = req.Priority
	payload.Fields.Labels = []string{"replayiq", "ai-generated"}

	// Jira Atlassian Document Format description
	payload.Fields.Description.Type = "doc"
	payload.Fields.Description.Version = 1
	payload.Fields.Description.Content = []struct {
		Type    string `json:"type"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}{
		{
			Type: "paragraph",
			Content: []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{
				{Type: "text", Text: req.Description},
			},
		},
		{
			Type: "paragraph",
			Content: []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			}{
				{Type: "text", Text: fmt.Sprintf("📹 Session Replay: Attached | Session ID: %s", req.SessionID)},
			},
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST",
		c.baseURL+"/rest/api/3/issue", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", c.authHeader)

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("jira http: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		var errBody map[string]any
		json.NewDecoder(resp.Body).Decode(&errBody)
		return nil, fmt.Errorf("jira error %d: %v", resp.StatusCode, errBody)
	}

	var result createIssueResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}

	return &models.JiraIssueResponse{
		Key:  result.Key,
		ID:   result.ID,
		Self: result.Self,
		URL:  fmt.Sprintf("%s/browse/%s", c.baseURL, result.Key),
	}, nil
}

// Webhook handler — Jira calls this when issues are updated
type WebhookEvent struct {
	WebhookEvent string `json:"webhookEvent"`
	Issue        struct {
		Key    string `json:"key"`
		Fields struct {
			Status struct {
				Name string `json:"name"`
			} `json:"status"`
			Assignee *struct {
				EmailAddress string `json:"emailAddress"`
			} `json:"assignee"`
		} `json:"fields"`
	} `json:"issue"`
}
