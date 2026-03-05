package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

const (
	tokenURL   = "https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/token/request"
	gangwayURL = "https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions"
)

type JobRequest struct {
	JobName          string `json:"job_name"`
	JobExecutionType string `json:"job_execution_type"`
	PodSpecOptions   struct {
		Envs map[string]string `json:"envs,omitempty"`
	} `json:"pod_spec_options,omitempty"`
}

func openBrowser(url string) error {
	switch runtime.GOOS {
	case "linux":
		return exec.Command("xdg-open", url).Start()
	case "darwin":
		return exec.Command("open", url).Start()
	default:
		return fmt.Errorf("unsupported platform %s", runtime.GOOS)
	}
}

func getToken(tokenFlag string) (string, error) {
	if tokenFlag != "" {
		return tokenFlag, nil
	}
	if t := os.Getenv("CI_TOKEN"); t != "" {
		return t, nil
	}

	fmt.Println("No token provided. Opening browser to get one...")
	fmt.Printf("If the browser doesn't open, visit:\n  %s\n\n", tokenURL)
	_ = openBrowser(tokenURL)

	fmt.Print("Paste your token: ")
	var token string
	fmt.Scanln(&token)
	token = strings.TrimSpace(token)
	if token == "" {
		return "", fmt.Errorf("no token provided")
	}
	return token, nil
}

func main() {
	token := flag.String("token", "", "Bearer token (or set CI_TOKEN env var)")
	execType := flag.String("type", "1", "Job execution type")
	envs := flag.String("envs", "", "Comma-separated KEY=VALUE pairs for pod spec envs")
	flag.Parse()

	args := flag.Args()
	if len(args) != 1 {
		fmt.Fprintf(os.Stderr, "Usage: %s [flags] <job-name>\n", os.Args[0])
		flag.PrintDefaults()
		os.Exit(1)
	}

	t, err := getToken(*token)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	req := JobRequest{
		JobName:          args[0],
		JobExecutionType: *execType,
	}
	req.PodSpecOptions.Envs = map[string]string{
		"MULTISTAGE_PARAM_OVERRIDE_ENFORCE_RUN": "yes",
	}
	if *envs != "" {
		for _, kv := range strings.Split(*envs, ",") {
			parts := strings.SplitN(kv, "=", 2)
			if len(parts) == 2 {
				req.PodSpecOptions.Envs[parts[0]] = parts[1]
			}
		}
	}

	body, err := json.Marshal(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	httpReq, err := http.NewRequest("POST", gangwayURL, bytes.NewReader(body))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	httpReq.Header.Set("Authorization", "Bearer "+t)
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		fmt.Fprintf(os.Stderr, "Error: %s\n%s\n", resp.Status, string(respBody))
		os.Exit(1)
	}

	var pretty bytes.Buffer
	if err := json.Indent(&pretty, respBody, "", "  "); err != nil {
		fmt.Println(string(respBody))
	} else {
		fmt.Println(pretty.String())
	}
}
