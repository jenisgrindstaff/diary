package app

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"diary/server/internal/diary"
)

func TestImportAndEntriesAPI(t *testing.T) {
	root := t.TempDir()
	imports := filepath.Join(root, "imports")
	if err := os.MkdirAll(imports, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imports, "2026-06-22-api.md"), []byte("# API\n\nHello API.\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	srv, err := New(Config{
		Addr:      ":0",
		VaultDir:  filepath.Join(root, "vault"),
		ImportDir: imports,
		DataDir:   filepath.Join(root, "data"),
		APIToken:  "secret",
	}, slog.New(slog.NewTextHandler(bytes.NewBuffer(nil), nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()

	handler := srv.Routes()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/admin/import", bytes.NewBufferString(`{}`))
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("import status %d body %s", rec.Code, rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/entries", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("entries status %d body %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		Entries []struct {
			Title string `json:"title"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Entries) != 1 || payload.Entries[0].Title != "API" {
		t.Fatalf("unexpected entries payload: %+v", payload)
	}
}

func TestAuthRejectsMissingToken(t *testing.T) {
	root := t.TempDir()
	srv, err := New(Config{
		Addr:      ":0",
		VaultDir:  filepath.Join(root, "vault"),
		ImportDir: filepath.Join(root, "imports"),
		DataDir:   filepath.Join(root, "data"),
		APIToken:  "secret",
	}, slog.New(slog.NewTextHandler(bytes.NewBuffer(nil), nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/entries", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d", rec.Code)
	}
}

func TestWebProxyAuthProtectsWebButNotAPI(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	srv.cfg.WebAuthHeader = "Remote-User"
	srv.cfg.WebAuthProxySecret = "proxy-secret"

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected web route unauthorized without proxy auth, got %d", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Remote-User", "jenny")
	rec = httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected missing proxy secret rejected, got %d", rec.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Remote-User", "jenny")
	req.Header.Set("X-Diary-Proxy-Secret", "proxy-secret")
	rec = httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected proxy-authenticated web route, got %d body %s", rec.Code, rec.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/entries", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec = httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected API bearer auth to bypass web proxy auth, got %d body %s", rec.Code, rec.Body.String())
	}
}

func TestShareRouteBypassesWebProxyAuth(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) == 0 {
		t.Fatal("expected imported entries")
	}

	srv.cfg.WebAuthHeader = "Remote-User"
	srv.cfg.WebAuthProxySecret = "proxy-secret"

	req := httptest.NewRequest(http.MethodGet, "/share/"+srv.shareToken(entries[0].ID), nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected signed share link to remain public, got %d body %s", rec.Code, rec.Body.String())
	}
}

func TestRegisterDeviceIssuesUsableToken(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	body := bytes.NewBufferString(`{
		"device_id": "ios-simulator",
		"display_name": "iPhone Simulator",
		"platform": "ios",
		"app_version": "1.0"
	}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/sync/register-device", body)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("register status %d body %s", rec.Code, rec.Body.String())
	}
	var payload struct {
		Device struct {
			DeviceID       string `json:"device_id"`
			DisplayName    string `json:"display_name"`
			Platform       string `json:"platform"`
			AppVersion     string `json:"app_version"`
			LastSyncCursor string `json:"last_sync_cursor"`
		} `json:"device"`
		DeviceToken string `json:"device_token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Device.DeviceID != "ios-simulator" || payload.DeviceToken == "" {
		t.Fatalf("unexpected registration payload %+v", payload)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/entries", nil)
	req.Header.Set("Authorization", "Bearer "+payload.DeviceToken)
	rec = httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("device token entries status %d body %s", rec.Code, rec.Body.String())
	}
	var syncPayload struct {
		NextCursor string `json:"next_cursor"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &syncPayload); err != nil {
		t.Fatal(err)
	}
	if syncPayload.NextCursor == "" {
		t.Fatal("expected sync cursor")
	}

	device, err := srv.store.Device("ios-simulator")
	if err != nil {
		t.Fatal(err)
	}
	if device.LastSyncCursor != syncPayload.NextCursor {
		t.Fatalf("expected cursor %q, got %q", syncPayload.NextCursor, device.LastSyncCursor)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/entries", nil)
	req.Header.Set("Authorization", "Bearer wrong-device-token")
	rec = httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected bad device token rejected, got %d", rec.Code)
	}
}

func TestCreateEntryAPI(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	body := bytes.NewBufferString(`{
		"date": "2026-06-27",
		"people": ["Charlotte", "Chase"],
		"tags": ["api"],
		"context": {
			"location": {"label": "Bar Harbor, ME", "precision": "place"},
			"weather": {"provider": "apple_weather", "condition": "Cloudy", "temperature_f": 72, "attribution": "Weather"},
			"activity": {"steps": 8432}
		},
		"body_markdown": "* Created from API."
	}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/entries", body)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("create status %d body %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		Entry diary.Entry `json:"entry"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Entry.ID == "" || payload.Entry.Title != "Created from API." {
		t.Fatalf("unexpected entry %+v", payload.Entry)
	}
	if len(payload.Entry.People) != 0 || len(payload.Entry.Tags) != 0 {
		t.Fatalf("manual API people/tags should be ignored, got people=%+v tags=%+v", payload.Entry.People, payload.Entry.Tags)
	}
	if payload.Entry.Context.Location == nil || payload.Entry.Context.Location.Label != "Bar Harbor, ME" {
		t.Fatalf("unexpected context %+v", payload.Entry.Context)
	}
	stored, err := srv.store.Entry(payload.Entry.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stored.VaultPath); err != nil {
		t.Fatal(err)
	}
	hits, err := srv.store.Search("Cloudy")
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) == 0 {
		t.Fatalf("expected context to be indexed")
	}
}

func TestCreateEntryAPIIsIdempotentForClientMutationID(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	requestBody := `{
		"created_at": "2026-06-27T12:00:00Z",
		"client_mutation_id": "queued-create-1",
		"title": "Retry Safe",
		"people": ["Charlotte"],
		"tags": ["api"],
		"body_markdown": "* Created once even if the client retries."
	}`

	create := func() diary.Entry {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/api/v1/entries", bytes.NewBufferString(requestBody))
		req.Header.Set("Authorization", "Bearer secret")
		req.Header.Set("X-Diary-Device-ID", "ios-device")
		rec := httptest.NewRecorder()
		srv.Routes().ServeHTTP(rec, req)

		if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
			t.Fatalf("create status %d body %s", rec.Code, rec.Body.String())
		}

		var payload struct {
			Entry diary.Entry `json:"entry"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		return payload.Entry
	}

	first := create()
	second := create()

	if first.ID != second.ID {
		t.Fatalf("expected retry to return same entry id, got %q then %q", first.ID, second.ID)
	}

	entries, err := srv.store.Search("Created once even if the client retries")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected exactly one indexed retried entry, got %d: %+v", len(entries), entries)
	}
}

func TestUpdateEntryAPI(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]
	body := bytes.NewBufferString(`{
		"date": "2026-06-28",
		"expected_server_revision": "` + entry.ServerRevision + `",
		"title": "Updated From API",
		"people": ["Charlotte"],
		"tags": ["api", "edited"],
		"body_markdown": "* Updated from API."
	}`)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/entries/"+entry.ID, body)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("update status %d body %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		Entry diary.Entry `json:"entry"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Entry.Title != "Updated From API" || payload.Entry.CreatedAt.Format("2006-01-02") != "2026-06-28" {
		t.Fatalf("unexpected updated entry %+v", payload.Entry)
	}
}

func TestUpdateEntryAPIRejectsStaleRevision(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]
	body := bytes.NewBufferString(`{
		"date": "2026-06-28",
		"expected_server_revision": "stale-revision",
		"title": "Updated From API",
		"people": ["Charlotte"],
		"tags": ["api", "edited"],
		"body_markdown": "* Updated from API."
	}`)
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/entries/"+entry.ID, body)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("update status %d body %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		Error string      `json:"error"`
		Entry diary.Entry `json:"entry"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Error == "" || payload.Entry.ID != entry.ID || payload.Entry.ServerRevision != entry.ServerRevision {
		t.Fatalf("unexpected conflict payload %+v", payload)
	}
}

func TestAttachMediaAPI(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]
	body, contentType := multipartBody(t, "media", "api photo.jpg", []byte("api image bytes"))
	req := httptest.NewRequest(http.MethodPost, "/api/v1/entries/"+entry.ID+"/attachments", body)
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("Content-Type", contentType)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("attach status %d body %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		Entry      diary.Entry      `json:"entry"`
		Attachment diary.Attachment `json:"attachment"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Attachment.Filename != "api-photo.jpg" || len(payload.Entry.Attachments) != 1 {
		t.Fatalf("unexpected attach payload %+v", payload)
	}
}

func TestRemoveMediaAPI(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]
	body, contentType := multipartBody(t, "media", "api photo.jpg", []byte("api image bytes"))
	attachReq := httptest.NewRequest(http.MethodPost, "/api/v1/entries/"+entry.ID+"/attachments", body)
	attachReq.Header.Set("Authorization", "Bearer secret")
	attachReq.Header.Set("Content-Type", contentType)
	attachRec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(attachRec, attachReq)
	if attachRec.Code != http.StatusCreated {
		t.Fatalf("attach status %d body %s", attachRec.Code, attachRec.Body.String())
	}
	var attachPayload struct {
		Entry      diary.Entry      `json:"entry"`
		Attachment diary.Attachment `json:"attachment"`
	}
	if err := json.Unmarshal(attachRec.Body.Bytes(), &attachPayload); err != nil {
		t.Fatal(err)
	}
	attachedPath := filepath.Join(srv.cfg.VaultDir, filepath.FromSlash(attachPayload.Attachment.MarkdownPath))
	if _, err := os.Stat(attachedPath); err != nil {
		t.Fatal(err)
	}

	removeReq := httptest.NewRequest(http.MethodDelete, "/api/v1/entries/"+entry.ID+"/attachments/"+attachPayload.Attachment.ID, nil)
	removeReq.Header.Set("Authorization", "Bearer secret")
	removeRec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(removeRec, removeReq)

	if removeRec.Code != http.StatusOK {
		t.Fatalf("remove status %d body %s", removeRec.Code, removeRec.Body.String())
	}
	var removePayload struct {
		Entry             diary.Entry      `json:"entry"`
		RemovedAttachment diary.Attachment `json:"removed_attachment"`
	}
	if err := json.Unmarshal(removeRec.Body.Bytes(), &removePayload); err != nil {
		t.Fatal(err)
	}
	if removePayload.RemovedAttachment.ID != attachPayload.Attachment.ID || len(removePayload.Entry.Attachments) != 0 {
		t.Fatalf("unexpected remove payload %+v", removePayload)
	}
	if _, err := os.Stat(attachedPath); !os.IsNotExist(err) {
		t.Fatalf("expected asset file removed, err=%v", err)
	}
}

func TestTrashEntryAPI(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]
	syncReq := httptest.NewRequest(http.MethodGet, "/api/v1/entries", nil)
	syncReq.Header.Set("Authorization", "Bearer secret")
	syncRec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(syncRec, syncReq)
	if syncRec.Code != http.StatusOK {
		t.Fatalf("sync status %d body %s", syncRec.Code, syncRec.Body.String())
	}
	var beforeSync struct {
		NextCursor string `json:"next_cursor"`
	}
	if err := json.Unmarshal(syncRec.Body.Bytes(), &beforeSync); err != nil {
		t.Fatal(err)
	}
	if beforeSync.NextCursor == "" {
		t.Fatal("expected initial sync cursor")
	}

	req := httptest.NewRequest(http.MethodDelete, "/api/v1/entries/"+entry.ID, nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("delete status %d body %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		DeletedEntryID string `json:"deleted_entry_id"`
		TrashPath      string `json:"trash_path"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.DeletedEntryID != entry.ID {
		t.Fatalf("unexpected delete payload %+v", payload)
	}
	if _, err := srv.store.Entry(entry.ID); err == nil {
		t.Fatal("expected deleted entry removed from index")
	}
	if _, err := os.Stat(payload.TrashPath); err != nil {
		t.Fatal(err)
	}

	syncReq = httptest.NewRequest(http.MethodGet, "/api/v1/entries?updated_since="+url.QueryEscape(beforeSync.NextCursor), nil)
	syncReq.Header.Set("Authorization", "Bearer secret")
	syncRec = httptest.NewRecorder()
	srv.Routes().ServeHTTP(syncRec, syncReq)
	if syncRec.Code != http.StatusOK {
		t.Fatalf("post-delete sync status %d body %s", syncRec.Code, syncRec.Body.String())
	}
	var afterSync struct {
		Entries         []diary.Entry `json:"entries"`
		DeletedEntryIDs []string      `json:"deleted_entry_ids"`
		NextCursor      string        `json:"next_cursor"`
	}
	if err := json.Unmarshal(syncRec.Body.Bytes(), &afterSync); err != nil {
		t.Fatal(err)
	}
	if len(afterSync.Entries) != 0 {
		t.Fatalf("expected no updated entries, got %+v", afterSync.Entries)
	}
	if len(afterSync.DeletedEntryIDs) != 1 || afterSync.DeletedEntryIDs[0] != entry.ID {
		t.Fatalf("unexpected deleted ids %+v", afterSync.DeletedEntryIDs)
	}
	if afterSync.NextCursor == "" || afterSync.NextCursor == beforeSync.NextCursor {
		t.Fatalf("expected cursor to advance from %q to %q", beforeSync.NextCursor, afterSync.NextCursor)
	}
}

// TestSearchReflectsIncrementalWrites verifies that the FTS index stays
// consistent through the incremental create/trash paths (no full reindex):
// a newly created entry is searchable, and a trashed one stops matching.
func TestSearchReflectsIncrementalWrites(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	body := bytes.NewBufferString(`{
		"date": "2026-07-01",
		"body_markdown": "* A zephyrwombat appeared today."
	}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/entries", body)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create status %d body %s", rec.Code, rec.Body.String())
	}
	var created struct {
		Entry diary.Entry `json:"entry"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}

	search := func() int {
		t.Helper()
		r := httptest.NewRequest(http.MethodGet, "/api/v1/search?q=zephyrwombat", nil)
		r.Header.Set("Authorization", "Bearer secret")
		w := httptest.NewRecorder()
		srv.Routes().ServeHTTP(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("search status %d body %s", w.Code, w.Body.String())
		}
		var payload struct {
			Entries []diary.Entry `json:"entries"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		return len(payload.Entries)
	}

	if got := search(); got != 1 {
		t.Fatalf("expected new entry to be searchable, got %d hits", got)
	}

	delReq := httptest.NewRequest(http.MethodDelete, "/api/v1/entries/"+created.Entry.ID, nil)
	delReq.Header.Set("Authorization", "Bearer secret")
	delRec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(delRec, delReq)
	if delRec.Code != http.StatusOK {
		t.Fatalf("delete status %d body %s", delRec.Code, delRec.Body.String())
	}

	if got := search(); got != 0 {
		t.Fatalf("expected trashed entry to drop out of search, got %d hits", got)
	}
}

func TestHomeRendersImportedEntries(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("home status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Diary") || !strings.Contains(body, "Charlotte") || !strings.Contains(body, "Chase") {
		t.Fatalf("home page did not include expected content:\n%s", body)
	}
}

func TestWebImportRedirectsWithStatus(t *testing.T) {
	root := t.TempDir()
	imports := filepath.Join(root, "imports")
	if err := os.MkdirAll(imports, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imports, "2026-06-22-web.md"), []byte("# Web\n\nHello web.\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	srv, err := New(Config{
		Addr:      ":0",
		VaultDir:  filepath.Join(root, "vault"),
		ImportDir: imports,
		DataDir:   filepath.Join(root, "data"),
		APIToken:  "secret",
	}, slog.New(slog.NewTextHandler(bytes.NewBuffer(nil), nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()

	req := httptest.NewRequest(http.MethodPost, "/admin/import", strings.NewReader("csrf_token="+webCSRFToken))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	withCSRFCookie(req)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("expected redirect, got %d body %s", rec.Code, rec.Body.String())
	}
	if location := rec.Header().Get("Location"); !strings.Contains(location, "Imported+1+entries") {
		t.Fatalf("unexpected redirect location %q", location)
	}
}

func TestNewEntryPageRendersForm(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	req := httptest.NewRequest(http.MethodGet, "/entries/new", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("new entry status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "New Entry") || !strings.Contains(body, `name="body_markdown"`) {
		t.Fatalf("expected new entry form:\n%s", body)
	}
	if !strings.Contains(body, `enctype="multipart/form-data"`) || !strings.Contains(body, `name="media"`) {
		t.Fatalf("expected media input on new entry form:\n%s", body)
	}
}

func TestCreateEntryRedirectsToDetail(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	body, contentType := multipartFormBody(t, map[string]string{
		"date":          "2026-06-24",
		"body_markdown": "* A fresh local entry.",
	}, nil)
	req := httptest.NewRequest(http.MethodPost, "/entries", body)
	req.Header.Set("Content-Type", contentType)
	withCSRFCookie(req)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("expected redirect, got %d body %s", rec.Code, rec.Body.String())
	}
	location := rec.Header().Get("Location")
	if !strings.HasPrefix(location, "/entries/") || !strings.Contains(location, "Created+entry") {
		t.Fatalf("unexpected redirect location %q", location)
	}

	entries, err := srv.store.Search("fresh local")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected one created entry, got %+v", entries)
	}
	entry := entries[0]
	if entry.Title != "A fresh local entry." {
		t.Fatalf("unexpected title %q", entry.Title)
	}
	if entry.SourcePath != "web" {
		t.Fatalf("unexpected source path %q", entry.SourcePath)
	}
	if len(entry.People) != 0 || len(entry.Tags) != 0 {
		t.Fatalf("web form should not set people/tags, got people=%+v tags=%+v", entry.People, entry.Tags)
	}
	if _, err := os.Stat(entry.VaultPath); err != nil {
		t.Fatal(err)
	}
}

func TestCreateEntryWithMedia(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	body, contentType := multipartFormBody(t, map[string]string{
		"date":          "2026-06-25",
		"title":         "Media From Start",
		"people":        "Charlotte",
		"body_markdown": "* Created with media.",
	}, []testUpload{{
		Field:    "media",
		Filename: "first image.jpg",
		Data:     []byte("initial upload bytes"),
	}})
	req := httptest.NewRequest(http.MethodPost, "/entries", body)
	req.Header.Set("Content-Type", contentType)
	withCSRFCookie(req)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("expected redirect, got %d body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Header().Get("Location"), "with+1+media+file") {
		t.Fatalf("unexpected redirect location %q", rec.Header().Get("Location"))
	}

	entries, err := srv.store.Search("Created with media")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected one created entry, got %+v", entries)
	}
	entry := entries[0]
	if len(entry.Attachments) != 1 {
		t.Fatalf("expected one attachment, got %+v", entry.Attachments)
	}
	attachment := entry.Attachments[0]
	if attachment.Filename != "first-image.jpg" || attachment.Kind != "image" {
		t.Fatalf("unexpected attachment %+v", attachment)
	}
	data, err := os.ReadFile(attachment.AbsolutePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "initial upload bytes" {
		t.Fatalf("unexpected attachment data %q", string(data))
	}
}

func TestWebEntryDetailRendersMarkdown(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) == 0 {
		t.Fatal("expected entries")
	}

	req := httptest.NewRequest(http.MethodGet, "/entries/"+entries[0].ID, nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("detail status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "<strong>") || !strings.Contains(body, "<li>") {
		t.Fatalf("expected rendered markdown in detail:\n%s", body)
	}
	if !strings.Contains(body, "Raw Markdown") {
		t.Fatalf("expected raw markdown disclosure")
	}
}

func TestEditEntryPageRendersForm(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]

	req := httptest.NewRequest(http.MethodGet, "/entries/"+entry.ID+"/edit", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("edit status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Edit Entry") || !strings.Contains(body, `action="/entries/`+entry.ID+`"`) {
		t.Fatalf("expected edit form:\n%s", body)
	}
	if strings.Contains(body, `name="media"`) {
		t.Fatalf("edit form should not include media input:\n%s", body)
	}
}

func TestUpdateEntryPreservesAttachments(t *testing.T) {
	srv := testServerWithMediaImport(t)
	defer srv.Close()

	entry := mediaEntry(t, srv)
	if len(entry.Attachments) == 0 {
		t.Fatal("expected attachments")
	}

	form := url.Values{}
	form.Set("date", "2026-06-26")
	form.Set("title", "Edited Media Day")
	form.Set("people", "Charlotte")
	form.Set("tags", "edited")
	form.Set("body_markdown", "* Edited body from the web.")
	form.Set("csrf_token", webCSRFToken)
	req := httptest.NewRequest(http.MethodPost, "/entries/"+entry.ID, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	withCSRFCookie(req)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("expected redirect, got %d body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Header().Get("Location"), "Updated+entry") {
		t.Fatalf("unexpected redirect location %q", rec.Header().Get("Location"))
	}

	updated, err := srv.store.Entry(entry.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Title != "Edited Media Day" {
		t.Fatalf("unexpected title %q", updated.Title)
	}
	if updated.CreatedAt.Format("2006-01-02") != "2026-06-26" {
		t.Fatalf("unexpected created date %s", updated.CreatedAt)
	}
	if len(updated.Attachments) != len(entry.Attachments) {
		t.Fatalf("attachments were not preserved: %+v", updated.Attachments)
	}
	if _, err := os.Stat(updated.VaultPath); err != nil {
		t.Fatal(err)
	}
}

func TestTrashEntryMovesFileAndReindexes(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]
	oldPath := entry.VaultPath

	req := httptest.NewRequest(http.MethodPost, "/entries/"+entry.ID+"/trash", strings.NewReader("csrf_token="+webCSRFToken))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	withCSRFCookie(req)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("expected redirect, got %d body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Header().Get("Location"), "Moved+entry+to+trash") {
		t.Fatalf("unexpected redirect location %q", rec.Header().Get("Location"))
	}
	if _, err := srv.store.Entry(entry.ID); err == nil {
		t.Fatalf("expected entry removed from index")
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("expected old path moved, err=%v", err)
	}

	trashRoot := filepath.Join(srv.cfg.VaultDir, "trash")
	found := false
	err = filepath.WalkDir(trashRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && filepath.Base(path) == filepath.Base(oldPath) {
			found = true
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatalf("expected trashed file under %s", trashRoot)
	}
}

func TestWebEntryDetailRendersMedia(t *testing.T) {
	srv := testServerWithMediaImport(t)
	defer srv.Close()

	entry := mediaEntry(t, srv)
	req := httptest.NewRequest(http.MethodGet, "/entries/"+entry.ID, nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("detail status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "<h2>Media</h2>") {
		t.Fatalf("expected media section:\n%s", body)
	}
	if !strings.Contains(body, "<img") || !strings.Contains(body, "<video") {
		t.Fatalf("expected image and video media:\n%s", body)
	}
	for _, attachment := range entry.Attachments {
		if !strings.Contains(body, "/assets/"+attachment.ID) {
			t.Fatalf("expected web asset path for %s:\n%s", attachment.ID, body)
		}
	}
}

func TestWebAssetRouteServesImportedAsset(t *testing.T) {
	srv := testServerWithMediaImport(t)
	defer srv.Close()

	entry := mediaEntry(t, srv)
	var imageID string
	for _, attachment := range entry.Attachments {
		if attachment.Kind == "image" {
			imageID = attachment.ID
			break
		}
	}
	if imageID == "" {
		t.Fatal("expected image attachment")
	}

	req := httptest.NewRequest(http.MethodGet, "/assets/"+imageID, nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("asset status %d body %s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("fake image")) {
		t.Fatalf("unexpected asset body %q", rec.Body.String())
	}
}

func TestWebAttachMediaUpdatesEntry(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) == 0 {
		t.Fatal("expected entries")
	}
	entry := entries[0]

	body, contentType := multipartBody(t, "media", "new photo.jpg", []byte("uploaded image bytes"))
	req := httptest.NewRequest(http.MethodPost, "/entries/"+entry.ID+"/attachments", body)
	req.Header.Set("Content-Type", contentType)
	withCSRFCookie(req)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("expected redirect, got %d body %s", rec.Code, rec.Body.String())
	}

	updated, err := srv.store.Entry(entry.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.Attachments) != 1 {
		t.Fatalf("expected one attachment, got %+v", updated.Attachments)
	}
	attachment := updated.Attachments[0]
	if attachment.Kind != "image" || attachment.Filename != "new-photo.jpg" {
		t.Fatalf("unexpected attachment: %+v", attachment)
	}
	data, err := os.ReadFile(attachment.AbsolutePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "uploaded image bytes" {
		t.Fatalf("unexpected uploaded data %q", string(data))
	}
	canonical, err := os.ReadFile(updated.VaultPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(canonical), "attachments:") || !strings.Contains(string(canonical), "new-photo.jpg") {
		t.Fatalf("canonical markdown missing attachment:\n%s", string(canonical))
	}
}

func TestHomeIgnoresSubjectFilterParam(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	req := httptest.NewRequest(http.MethodGet, "/?subject=Charlotte", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("home status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Hello from the web") || !strings.Contains(body, "Another entry") {
		t.Fatalf("subject query parameter should not filter entries:\n%s", body)
	}
}

func TestSearchAPI(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/search?q=another", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("search status %d body %s", rec.Code, rec.Body.String())
	}

	var payload struct {
		Query   string `json:"query"`
		Entries []struct {
			Title  string   `json:"title"`
			People []string `json:"people"`
		} `json:"entries"`
		Snippets []struct {
			EntryID string `json:"entry_id"`
			Text    string `json:"text"`
		} `json:"snippets"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Query != "another" {
		t.Fatalf("unexpected query %q", payload.Query)
	}
	if len(payload.Entries) != 1 || payload.Entries[0].People[0] != "Chase" {
		t.Fatalf("unexpected search results: %+v", payload.Entries)
	}
	if len(payload.Snippets) != 1 || !strings.Contains(payload.Snippets[0].Text, "[[Another]]") {
		t.Fatalf("unexpected snippets: %+v", payload.Snippets)
	}
}

func TestHomeArchiveFilter(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	req := httptest.NewRequest(http.MethodGet, "/?year=2026&month=06", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("home status %d body %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "2 Entries") || !strings.Contains(body, "June 2026") {
		t.Fatalf("expected June archive entries:\n%s", body)
	}
	if !strings.Contains(body, `href="/"`) {
		t.Fatalf("expected clear link for archive filter:\n%s", body)
	}
}

func TestCleanExcerptStripsMarkdownMarkers(t *testing.T) {
	excerpt := cleanExcerpt("**Charlotte:** 8 years\n* Chase has started reading")
	if strings.Contains(excerpt, "**") || strings.Contains(excerpt, "* ") {
		t.Fatalf("excerpt still contains markdown markers: %q", excerpt)
	}
	if !strings.Contains(excerpt, "Charlotte:") || !strings.Contains(excerpt, "Chase has started reading") {
		t.Fatalf("excerpt lost content: %q", excerpt)
	}
}

func multipartBody(t *testing.T, field string, filename string, data []byte) (*bytes.Buffer, string) {
	t.Helper()

	return multipartFormBody(t, nil, []testUpload{{
		Field:    field,
		Filename: filename,
		Data:     data,
	}})
}

type testUpload struct {
	Field    string
	Filename string
	Data     []byte
}

func TestWebFormRejectsMissingCSRF(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]

	// No cookie, no token field → rejected.
	req := httptest.NewRequest(http.MethodPost, "/entries/"+entry.ID+"/trash", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 without CSRF, got %d", rec.Code)
	}

	// Cookie present but form field mismatched → still rejected.
	req = httptest.NewRequest(http.MethodPost, "/entries/"+entry.ID+"/trash", strings.NewReader("csrf_token=wrong"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	withCSRFCookie(req)
	rec = httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 on token mismatch, got %d", rec.Code)
	}
}

func TestNewEntryFormSetsCSRFCookieAndField(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	req := httptest.NewRequest(http.MethodGet, "/entries/new", nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)

	var token string
	for _, c := range rec.Result().Cookies() {
		if c.Name == "csrf_token" {
			token = c.Value
		}
	}
	if token == "" {
		t.Fatal("expected csrf_token cookie to be set")
	}
	if !strings.Contains(rec.Body.String(), `name="csrf_token" value="`+token+`"`) {
		t.Fatal("expected matching csrf_token hidden field in the form")
	}
}

func TestShareTokenRoundTripAndTamper(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	token := srv.shareToken("entry-123")
	id, ok := srv.verifyShareToken(token)
	if !ok || id != "entry-123" {
		t.Fatalf("round trip failed: id=%q ok=%v", id, ok)
	}
	if _, ok := srv.verifyShareToken(token + "x"); ok {
		t.Fatal("tampered token should be rejected")
	}
	if _, ok := srv.verifyShareToken("garbage"); ok {
		t.Fatal("garbage token should be rejected")
	}
}

func TestShareLinkRendersReadOnlyEntry(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	entry := entries[0]

	req := httptest.NewRequest(http.MethodGet, "/share/"+srv.shareToken(entry.ID), nil)
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("share status %d body %s", rec.Code, rec.Body.String())
	}

	body := rec.Body.String()
	if !strings.Contains(body, entry.Title) {
		t.Fatal("share page should show the entry title")
	}
	for _, forbidden := range []string{"Move to Trash", "/admin/reindex", "/admin/import", "/edit"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("share page must not expose %q:\n%s", forbidden, body)
		}
	}

	// Invalid token is a 404.
	bad := httptest.NewRequest(http.MethodGet, "/share/not-a-real-token", nil)
	badRec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(badRec, bad)
	if badRec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for invalid share token, got %d", badRec.Code)
	}
}

func TestFilterEntriesByArchiveDate(t *testing.T) {
	entries := []diary.Entry{
		{ID: "a", CreatedAt: time.Date(2026, 7, 2, 0, 0, 0, 0, time.UTC)},
		{ID: "b", CreatedAt: time.Date(2026, 8, 2, 0, 0, 0, 0, time.UTC)},
		{ID: "c", CreatedAt: time.Date(2025, 7, 2, 0, 0, 0, 0, time.UTC)},
	}
	got := filterEntries(entries, "2026", "07")
	if len(got) != 1 || got[0].ID != "a" {
		t.Fatalf("expected only entry a for July 2026, got %+v", got)
	}
	if len(filterEntries(entries, "2024", "")) != 0 {
		t.Fatal("expected no entries for an unused year")
	}
}

func TestHomeOmitsTagFilter(t *testing.T) {
	srv := testServerWithImport(t)
	defer srv.Close()

	// Legacy clients may still submit a tag-shaped field, but the web flow no
	// longer treats tags as user-facing metadata.
	form, contentType := multipartFormBody(t, map[string]string{
		"date":          "2026-07-02",
		"title":         "Tagged",
		"body_markdown": "* Has a unique tag.",
		"tags":          "uniquetag",
	}, nil)
	req := withCSRFCookie(httptest.NewRequest(http.MethodPost, "/entries", form))
	req.Header.Set("Content-Type", contentType)
	srv.Routes().ServeHTTP(httptest.NewRecorder(), req)

	home := httptest.NewRecorder()
	srv.Routes().ServeHTTP(home, httptest.NewRequest(http.MethodGet, "/", nil))
	if strings.Contains(home.Body.String(), "#uniquetag") {
		t.Fatal("tag chip should not be shown on the home page")
	}
}

func multipartFormBody(t *testing.T, values map[string]string, uploads []testUpload) (*bytes.Buffer, string) {
	t.Helper()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if _, ok := values["csrf_token"]; !ok {
		if err := writer.WriteField("csrf_token", webCSRFToken); err != nil {
			t.Fatal(err)
		}
	}
	for key, value := range values {
		if err := writer.WriteField(key, value); err != nil {
			t.Fatal(err)
		}
	}
	for _, upload := range uploads {
		part, err := writer.CreateFormFile(upload.Field, upload.Filename)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write(upload.Data); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return &body, writer.FormDataContentType()
}

const webCSRFToken = "test-csrf-token"

// withCSRFCookie attaches the cookie half of the double-submit CSRF token so a
// test POST matches the csrf_token form field that multipartFormBody / the form
// values carry.
func withCSRFCookie(req *http.Request) *http.Request {
	req.AddCookie(&http.Cookie{Name: "csrf_token", Value: webCSRFToken})
	return req
}

func mediaEntry(t *testing.T, srv *Server) diary.Entry {
	t.Helper()

	entries, err := srv.store.Entries()
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if len(entry.Attachments) > 0 {
			return entry
		}
	}
	t.Fatal("expected entry with attachments")
	return diary.Entry{}
}

func testServerWithImport(t *testing.T) *Server {
	t.Helper()

	root := t.TempDir()
	imports := filepath.Join(root, "imports")
	if err := os.MkdirAll(imports, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imports, "2026-06-22-api.md"), []byte("#### 2026-06-22\n**Charlotte**\n* Hello from the web.\n\n____\n\n#### 2026-06-23\n**Chase**\n* Another entry.\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	srv, err := New(Config{
		Addr:      ":0",
		VaultDir:  filepath.Join(root, "vault"),
		ImportDir: imports,
		DataDir:   filepath.Join(root, "data"),
		APIToken:  "secret",
	}, slog.New(slog.NewTextHandler(bytes.NewBuffer(nil), nil)))
	if err != nil {
		t.Fatal(err)
	}

	result, err := srv.importer.Import(imports)
	if err != nil {
		srv.Close()
		t.Fatal(err)
	}
	if result.ImportedEntries == 0 {
		srv.Close()
		t.Fatal("expected imported entries")
	}
	if err := srv.Reindex(); err != nil {
		srv.Close()
		t.Fatal(err)
	}

	return srv
}

func testServerWithMediaImport(t *testing.T) *Server {
	t.Helper()

	root := t.TempDir()
	imports := filepath.Join(root, "imports")
	if err := os.MkdirAll(filepath.Join(imports, "media"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imports, "media", "photo.jpg"), []byte("fake image bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(imports, "media", "clip.mov"), []byte("fake video bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	body := "# Media Day\n\n![photo](media/photo.jpg)\n\n[clip](media/clip.mov)\n"
	if err := os.WriteFile(filepath.Join(imports, "2026-06-24-media.md"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	srv, err := New(Config{
		Addr:      ":0",
		VaultDir:  filepath.Join(root, "vault"),
		ImportDir: imports,
		DataDir:   filepath.Join(root, "data"),
		APIToken:  "secret",
	}, slog.New(slog.NewTextHandler(bytes.NewBuffer(nil), nil)))
	if err != nil {
		t.Fatal(err)
	}

	result, err := srv.importer.Import(imports)
	if err != nil {
		srv.Close()
		t.Fatal(err)
	}
	if result.ImportedEntries != 1 || result.ImportedAssets != 2 {
		srv.Close()
		t.Fatalf("unexpected import result: %+v", result)
	}
	if err := srv.Reindex(); err != nil {
		srv.Close()
		t.Fatal(err)
	}

	return srv
}
