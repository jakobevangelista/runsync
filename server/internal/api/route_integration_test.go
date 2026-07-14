package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jakobevangelista/runsync/server/internal/auth"
	"github.com/jakobevangelista/runsync/server/internal/database"
	"github.com/jakobevangelista/runsync/server/internal/live"
)

func TestRouteHTTPIntegration(t *testing.T) {
	databaseURL := os.Getenv("RUNSYNC_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("RUNSYNC_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := database.Open(ctx, databaseURL, 4)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err := database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}

	fixture := newRouteFixture(t, pool)
	key := bytes.Repeat([]byte{3}, 32)
	server := httptest.NewServer(New(pool, key, nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler())
	defer server.Close()

	request := func(slug, token string) (*http.Response, []byte) {
		t.Helper()
		req, err := http.NewRequest(http.MethodGet, server.URL+"/v1/channels/"+slug+"/route", nil)
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		response, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		body, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatal(err)
		}
		return response, body
	}
	decodeRoute := func(body []byte) live.Route {
		t.Helper()
		var route live.Route
		if err := json.Unmarshal(body, &route); err != nil {
			t.Fatalf("decode route: %v: %s", err, body)
		}
		return route
	}

	t.Run("authentication", func(t *testing.T) {
		response, _ := request(fixture.preciseSlug, "")
		if response.StatusCode != http.StatusUnauthorized || response.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("missing token: status=%d cache=%q", response.StatusCode, response.Header.Get("Cache-Control"))
		}
		response, _ = request(fixture.preciseSlug, fixture.writeToken)
		if response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("wrong scope: status=%d", response.StatusCode)
		}
		response, _ = request(fixture.preciseSlug, fixture.otherToken)
		if response.StatusCode != http.StatusNotFound {
			t.Fatalf("cross-user request: status=%d", response.StatusCode)
		}
	})

	t.Run("precise service route", func(t *testing.T) {
		response, body := request(fixture.preciseSlug, fixture.readToken)
		if response.StatusCode != http.StatusOK || response.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("status=%d cache=%q body=%s", response.StatusCode, response.Header.Get("Cache-Control"), body)
		}
		route := decodeRoute(body)
		if route.ChannelID != fixture.preciseChannel || route.ActivityID == nil || *route.ActivityID != fixture.activity || route.LocationPolicy != "precise" {
			t.Fatalf("route identity=%#v", route)
		}
		if len(route.Points) != 3 || route.Points[0].EnvelopeID != fixture.firstEnvelope || route.Points[1].EnvelopeID != fixture.secondEnvelope || route.Points[2].EnvelopeID != fixture.latestEnvelope {
			t.Fatalf("point order=%#v", route.Points)
		}
		if route.Points[0].LatitudeMicrodegrees != 37774921 || route.Points[0].LongitudeMicrodegrees != -122419381 {
			t.Fatalf("coordinates=%#v", route.Points[0])
		}
		var raw map[string]any
		if err := json.Unmarshal(body, &raw); err != nil {
			t.Fatal(err)
		}
		for _, forbidden := range []string{"userId", "installationId", "garminDeviceIdentifier", "credentialId"} {
			if _, ok := raw[forbidden]; ok {
				t.Fatalf("response includes %s", forbidden)
			}
		}
	})

	t.Run("viewer policy clamp", func(t *testing.T) {
		decimals := int16(2)
		now := time.Now().UTC()
		token, err := auth.SignViewer(key, auth.ViewerClaims{ChannelID: fixture.preciseChannel, UserID: fixture.user, Slug: fixture.preciseSlug, Policy: "rounded", Decimals: &decimals, IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Minute).Unix(), Scope: "channel:live"})
		if err != nil {
			t.Fatal(err)
		}
		response, body := request(fixture.preciseSlug, token)
		route := decodeRoute(body)
		if response.StatusCode != http.StatusOK || route.LocationPolicy != "rounded" || len(route.Points) != 3 {
			t.Fatalf("status=%d route=%#v", response.StatusCode, route)
		}
		if route.Points[0].LatitudeMicrodegrees != 37770000 || route.Points[0].LongitudeMicrodegrees != -122420000 {
			t.Fatalf("clamped coordinates=%#v", route.Points[0])
		}
	})

	t.Run("configured rounded and hidden policies", func(t *testing.T) {
		response, body := request(fixture.roundedSlug, fixture.readToken)
		rounded := decodeRoute(body)
		if response.StatusCode != http.StatusOK || rounded.LocationPolicy != "rounded" || len(rounded.Points) != 3 || rounded.Points[0].LatitudeMicrodegrees != 37775000 || rounded.Points[0].LongitudeMicrodegrees != -122419000 {
			t.Fatalf("rounded status=%d route=%#v", response.StatusCode, rounded)
		}
		response, body = request(fixture.hiddenSlug, fixture.readToken)
		hidden := decodeRoute(body)
		if response.StatusCode != http.StatusOK || hidden.LocationPolicy != "hidden" || len(hidden.Points) != 0 {
			t.Fatalf("hidden status=%d route=%#v", response.StatusCode, hidden)
		}
	})

	t.Run("empty and unavailable", func(t *testing.T) {
		for _, slug := range []string{fixture.emptySlug, fixture.unavailableSlug} {
			response, body := request(slug, fixture.readToken)
			route := decodeRoute(body)
			if response.StatusCode != http.StatusOK || len(route.Points) != 0 {
				t.Fatalf("slug=%s status=%d route=%#v", slug, response.StatusCode, route)
			}
		}
	})

	t.Run("long route is deterministic and bounded", func(t *testing.T) {
		response, body := request(fixture.longSlug, fixture.readToken)
		first := decodeRoute(body)
		if response.StatusCode != http.StatusOK || len(first.Points) != 5000 {
			t.Fatalf("status=%d points=%d", response.StatusCode, len(first.Points))
		}
		if first.Points[0].LatitudeMicrodegrees != 10000001 || first.Points[len(first.Points)-1].LatitudeMicrodegrees != 10005001 {
			t.Fatalf("endpoints=%#v %#v", first.Points[0], first.Points[len(first.Points)-1])
		}
		_, body = request(fixture.longSlug, fixture.readToken)
		second := decodeRoute(body)
		for i := range first.Points {
			if first.Points[i].EnvelopeID != second.Points[i].EnvelopeID {
				t.Fatalf("non-deterministic point at %d", i)
			}
		}
	})

	t.Run("snapshot keeps old ended latest", func(t *testing.T) {
		req, err := http.NewRequest(http.MethodGet, server.URL+"/v1/channels/"+fixture.endedSlug+"/snapshot", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+fixture.readToken)
		response, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		var snapshot live.Snapshot
		if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != http.StatusOK || snapshot.Status != "ended" || snapshot.Latest == nil || snapshot.Latest.EnvelopeID != fixture.endedEnvelope || len(snapshot.Route) != 0 {
			t.Fatalf("status=%d snapshot=%#v", response.StatusCode, snapshot)
		}
	})
}

type routeFixture struct {
	user                                                                       uuid.UUID
	activity                                                                   uuid.UUID
	preciseChannel                                                             uuid.UUID
	firstEnvelope, secondEnvelope, latestEnvelope, endedEnvelope               uuid.UUID
	preciseSlug, roundedSlug, hiddenSlug, emptySlug, unavailableSlug, longSlug string
	endedSlug, readToken, writeToken, otherToken                               string
}

func newRouteFixture(t *testing.T, pool *pgxpool.Pool) routeFixture {
	t.Helper()
	ctx := context.Background()
	suffix := uuid.New().String()[:8]
	f := routeFixture{
		user: uuid.New(), activity: uuid.New(), preciseChannel: uuid.New(),
		firstEnvelope: uuid.New(), secondEnvelope: uuid.New(), latestEnvelope: uuid.New(), endedEnvelope: uuid.New(),
		preciseSlug: "precise-" + suffix, roundedSlug: "rounded-" + suffix, hiddenSlug: "hidden-" + suffix,
		emptySlug: "empty-" + suffix, unavailableSlug: "unavailable-" + suffix, longSlug: "long-" + suffix, endedSlug: "ended-" + suffix,
	}
	otherUser := uuid.New()
	installation, device := uuid.New(), uuid.New()
	longActivity, unavailableActivity, endedActivity := uuid.New(), uuid.New(), uuid.New()
	now := time.Now().UTC().Truncate(time.Millisecond)

	mustExec := func(query string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, query, args...); err != nil {
			t.Fatal(err)
		}
	}
	mustExec(`INSERT INTO users(id,handle) VALUES($1,$2),($3,$4)`, f.user, "route-"+suffix, otherUser, "other-"+suffix)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM telemetry_samples WHERE user_id=ANY($1); DELETE FROM live_channels WHERE user_id=ANY($1); DELETE FROM activities WHERE user_id=ANY($1); DELETE FROM api_credentials WHERE user_id=ANY($1); DELETE FROM garmin_devices WHERE user_id=ANY($1); DELETE FROM installations WHERE user_id=ANY($1); DELETE FROM users WHERE id=ANY($1)`, []uuid.UUID{f.user, otherUser})
	})
	mustExec(`INSERT INTO installations(id,user_id,first_seen_at,last_seen_at,app_version) VALUES($1,$2,$3,$3,'test')`, installation, f.user, now)
	mustExec(`INSERT INTO garmin_devices(id,user_id,garmin_identifier,first_seen_at,last_seen_at) VALUES($1,$2,$3,$4,$4)`, device, f.user, uuid.New(), now)
	for _, activity := range []uuid.UUID{f.activity, longActivity, unavailableActivity, endedActivity} {
		mustExec(`INSERT INTO activities(id,user_id,installation_id,garmin_device_id,first_phone_received_at,last_phone_received_at,first_server_received_at,last_server_received_at,current_state) VALUES($1,$2,$3,$4,$5,$5,$5,$5,1)`, activity, f.user, installation, device, now)
	}

	readToken := insertRouteCredential(t, pool, f.user, []string{"channels:read"})
	writeToken := insertRouteCredential(t, pool, f.user, []string{"telemetry:write"})
	otherToken := insertRouteCredential(t, pool, otherUser, []string{"channels:read"})
	f.readToken, f.writeToken, f.otherToken = readToken, writeToken, otherToken

	decimals := int16(3)
	mustExec(`INSERT INTO live_channels(id,user_id,slug,display_name,active_activity_id,location_policy,coordinate_decimals) VALUES
		($1,$2,$3,'Precise',$4,'precise',NULL),
		($5,$2,$6,'Rounded',$4,'rounded',$7),
		($8,$2,$9,'Hidden',$4,'hidden',NULL),
		($10,$2,$11,'Empty',NULL,'precise',NULL),
		($12,$2,$13,'Unavailable',$14,'precise',NULL),
		($15,$2,$16,'Long',$17,'precise',NULL),
		($18,$2,$19,'Ended',$20,'precise',NULL)`,
		f.preciseChannel, f.user, f.preciseSlug, f.activity,
		uuid.New(), f.roundedSlug, decimals,
		uuid.New(), f.hiddenSlug,
		uuid.New(), f.emptySlug,
		uuid.New(), f.unavailableSlug, unavailableActivity,
		uuid.New(), f.longSlug, longActivity,
		uuid.New(), f.endedSlug, endedActivity)

	insertSample := func(id, activity uuid.UUID, cursor int64, at time.Time, state int16, lat, lon *int) {
		t.Helper()
		mustExec(`INSERT INTO telemetry_samples(envelope_id,activity_id,user_id,phone_received_at,server_received_at,ingest_cursor,app_version,protocol_version,watch_sequence,activity_state,latitude_microdegrees,longitude_microdegrees,gps_quality) VALUES($1,$2,$3,$4,$5,$6,'test',1,$7,$8,$9,$10,4)`, id, activity, f.user, at, now, cursor, int(cursor), state, lat, lon)
	}
	lat1, lon1 := 37774921, -122419381
	lat2, lon2 := 37774922, -122419382
	lat3, lon3 := 37774923, -122419383
	tiedAt := now.Add(-2 * time.Hour)
	insertSample(f.firstEnvelope, f.activity, 1, tiedAt, 1, &lat1, &lon1)
	insertSample(f.secondEnvelope, f.activity, 2, tiedAt, 1, &lat2, &lon2)
	insertSample(f.latestEnvelope, f.activity, 3, tiedAt.Add(time.Second), 4, &lat3, &lon3)
	insertSample(uuid.New(), unavailableActivity, 4, tiedAt, 1, nil, nil)
	insertSample(f.endedEnvelope, endedActivity, 5, now.Add(-time.Hour), 4, &lat3, &lon3)
	mustExec(`UPDATE activities SET current_state=4,last_phone_received_at=$2,latest_ingest_cursor=5,ended_at=$2 WHERE id=$1`, endedActivity, now.Add(-time.Hour))
	mustExec(`INSERT INTO telemetry_samples(envelope_id,activity_id,user_id,phone_received_at,server_received_at,ingest_cursor,app_version,protocol_version,watch_sequence,activity_state,latitude_microdegrees,longitude_microdegrees,gps_quality)
		SELECT md5($1::text || ':' || g::text)::uuid,$2,$3,$4::timestamptz + g * interval '1 second',$5,100 + g,'test',1,g,1,10000000 + g,20000000 + g,3 FROM generate_series(1,5001) AS g`, longActivity, longActivity, f.user, now.Add(-4*time.Hour), now)

	return f
}

func insertRouteCredential(t *testing.T, pool *pgxpool.Pool, user uuid.UUID, scopes []string) string {
	t.Helper()
	token, prefix, hash, err := auth.GenerateToken()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(context.Background(), `INSERT INTO api_credentials(id,user_id,name,token_prefix,token_hash,scopes) VALUES($1,$2,$3,$4,$5,$6)`, uuid.New(), user, fmt.Sprintf("route-%s", uuid.New()), prefix, hash, scopes); err != nil {
		t.Fatal(err)
	}
	return token
}
