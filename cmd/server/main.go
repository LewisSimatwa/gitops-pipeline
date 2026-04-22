package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()

	// Health endpoints required by Kyverno + Helm chart probes
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ready")
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		env := os.Getenv("APP_ENV")
		if env == "" {
			env = "unknown"
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "GitOps demo app — env: %s\n", env)
	})

	log.Printf("Starting server on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}