package webserver

import (
	"crypto/subtle"
	"net/http"
	"strings"
)

// requireBearer wraps next with constant-time Bearer token validation. A
// missing or mismatched token yields 401 without leaking length/timing.
func requireBearer(token, corsOrigin string, next http.HandlerFunc) http.HandlerFunc {
	want := []byte(token)
	return func(w http.ResponseWriter, r *http.Request) {
		got := []byte(bearerToken(r))
		if subtle.ConstantTimeEq(int32(len(got)), int32(len(want))) != 1 ||
			subtle.ConstantTimeCompare(got, want) != 1 {
			setCORS(w, corsOrigin)
			writeError(w, http.StatusUnauthorized, "missing or invalid bearer token")
			return
		}
		next(w, r)
	}
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) > len(prefix) && strings.EqualFold(h[:len(prefix)], prefix) {
		return strings.TrimSpace(h[len(prefix):])
	}
	return ""
}
