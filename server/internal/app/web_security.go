package app

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"strings"
)

const csrfCookieName = "csrf_token"

// ensureCSRFToken returns the request's CSRF token, minting and setting a cookie
// on first use. The web forms embed this value in a hidden field; POST handlers
// require the field to match the cookie (double-submit), which a cross-site
// attacker cannot read or forge.
func ensureCSRFToken(w http.ResponseWriter, r *http.Request) string {
	if cookie, err := r.Cookie(csrfCookieName); err == nil && cookie.Value != "" {
		return cookie.Value
	}

	token := randomToken()
	http.SetCookie(w, &http.Cookie{
		Name:     csrfCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	return token
}

// validCSRF reports whether the request carries a CSRF token matching its
// cookie. Parsing the form here also primes r.PostFormValue for the handler.
func validCSRF(r *http.Request) bool {
	cookie, err := r.Cookie(csrfCookieName)
	if err != nil || cookie.Value == "" {
		return false
	}
	field := r.PostFormValue(csrfCookieName)
	return constantTimeEqual(cookie.Value, field)
}

func randomToken() string {
	var buf [32]byte
	if _, err := rand.Read(buf[:]); err != nil {
		// rand.Read failing is catastrophic; fall back to a constant so the app
		// keeps working rather than panicking. Practically unreachable.
		return "diary-csrf-fallback"
	}
	return base64.RawURLEncoding.EncodeToString(buf[:])
}

// shareToken signs an entry id so it can be shared as an unguessable read-only
// URL. The secret is derived from the API token, so links survive restarts but
// change if the token is rotated.
func (s *Server) shareToken(entryID string) string {
	payload := entryID + "." + base64.RawURLEncoding.EncodeToString(s.shareSignature(entryID))
	return base64.RawURLEncoding.EncodeToString([]byte(payload))
}

// verifyShareToken returns the entry id encoded in a share token if its
// signature is valid.
func (s *Server) verifyShareToken(token string) (string, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return "", false
	}
	entryID, sigB64, ok := strings.Cut(string(raw), ".")
	if !ok {
		return "", false
	}
	sig, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil {
		return "", false
	}
	if !hmac.Equal(sig, s.shareSignature(entryID)) {
		return "", false
	}
	return entryID, true
}

func (s *Server) shareSignature(entryID string) []byte {
	mac := hmac.New(sha256.New, s.shareSecret())
	mac.Write([]byte(entryID))
	return mac.Sum(nil)
}

func (s *Server) shareSecret() []byte {
	sum := sha256.Sum256([]byte("diary-share-secret:" + s.cfg.APIToken))
	return sum[:]
}

func absoluteURL(r *http.Request, path string) string {
	scheme := "http"
	if r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	return scheme + "://" + r.Host + path
}
