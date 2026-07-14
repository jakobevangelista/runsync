package live

import (
	"reflect"
	"testing"

	"github.com/google/uuid"
)

func TestDownsamplePreservesEndpointsDeterministically(t *testing.T) {
	points := make([]RoutePoint, 11)
	for i := range points {
		points[i].EnvelopeID = uuid.New()
	}

	first := downsample(points, 5)
	second := downsample(points, 5)
	if len(first) != 5 {
		t.Fatalf("len=%d", len(first))
	}
	if first[0] != points[0] || first[len(first)-1] != points[len(points)-1] {
		t.Fatal("downsampling did not preserve endpoints")
	}
	if !reflect.DeepEqual(first, second) {
		t.Fatal("downsampling is not deterministic")
	}
}
