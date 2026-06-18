package api

import "net/http"

// GET /api/v1/issues?project_id=
func (r *router) handleIssues(w http.ResponseWriter, req *http.Request) {
	projectID := req.URL.Query().Get("project_id")
	issues, err := r.cfg.DB.ListIssues(req.Context(), projectID, 50)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"issues": issues})
}
