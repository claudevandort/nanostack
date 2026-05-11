// Helpers shared across the M1 conformance tests.
package conformance

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func endpoint() string {
	if e := os.Getenv("NANOSTACK_ENDPOINT"); e != "" {
		return e
	}
	return "http://127.0.0.1:4577"
}

// endpointHost returns the Host header value the SDK should sign with —
// derived from NANOSTACK_ENDPOINT so tests work on any port. CI uses
// 14566; local dev typically uses 4577.
func endpointHost() string {
	u, err := url.Parse(endpoint())
	if err != nil {
		return "127.0.0.1:4577"
	}
	return u.Host
}

func newClient(t *testing.T) *s3.Client {
	t.Helper()
	return s3.New(s3.Options{
		Region:       "us-east-1",
		Credentials:  credentials.NewStaticCredentialsProvider("test", "test", ""),
		BaseEndpoint: aws.String(endpoint()),
		UsePathStyle: true,
		HTTPClient:   &http.Client{Timeout: 5 * time.Second},
	})
}

// uniqueBucketName produces a name that's guaranteed not to clash with
// other concurrent tests. It also stays inside AWS's strict naming rules.
func uniqueBucketName(t *testing.T, prefix string) string {
	t.Helper()
	clean := strings.ToLower(t.Name())
	clean = strings.ReplaceAll(clean, "_", "-")
	clean = strings.ReplaceAll(clean, "/", "-")
	if len(clean) > 30 {
		clean = clean[:30]
	}
	return fmt.Sprintf("%s-%s-%d", prefix, clean, time.Now().UnixNano())
}
