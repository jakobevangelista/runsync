package api

import (
	"context"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/live"
)

const bootstrapCacheTTL = 30 * time.Second

// Bootstrap includes the potentially expensive full activity route. Short
// caching protects page-load and five-minute token-refresh stampedes, while
// newly committed telemetry invalidates every affected channel immediately.
type bootstrapCache struct {
	mu          sync.Mutex
	entries     map[bootstrapCacheKey]bootstrapCacheEntry
	flights     map[bootstrapFlightKey]*bootstrapFlight
	generations map[uuid.UUID]uint64
}

type bootstrapCacheKey struct {
	channelID   uuid.UUID
	activityID  uuid.UUID
	hasActivity bool
	policy      string
	decimals    int16
	hasDecimals bool
}

type bootstrapCacheEntry struct {
	value     live.Bootstrap
	expiresAt time.Time
}

type bootstrapFlightKey struct {
	bootstrapCacheKey
	generation uint64
}

type bootstrapFlight struct {
	done  chan struct{}
	value live.Bootstrap
	err   error
}

type bootstrapLoader func(context.Context, live.Channel, time.Time) (live.Bootstrap, error)

func newBootstrapCache() *bootstrapCache {
	return &bootstrapCache{
		entries:     map[bootstrapCacheKey]bootstrapCacheEntry{},
		flights:     map[bootstrapFlightKey]*bootstrapFlight{},
		generations: map[uuid.UUID]uint64{},
	}
}

func (c *bootstrapCache) get(
	ctx context.Context,
	channel live.Channel,
	now time.Time,
	load bootstrapLoader,
) (live.Bootstrap, error) {
	key := newBootstrapCacheKey(channel)

	c.mu.Lock()
	c.pruneExpiredLocked(now)
	if entry, ok := c.entries[key]; ok {
		c.mu.Unlock()
		return entry.value, nil
	}
	flightKey := bootstrapFlightKey{
		bootstrapCacheKey: key,
		generation:        c.generations[channel.ID],
	}
	if flight := c.flights[flightKey]; flight != nil {
		c.mu.Unlock()
		select {
		case <-ctx.Done():
			return live.Bootstrap{}, ctx.Err()
		case <-flight.done:
			return flight.value, flight.err
		}
	}
	flight := &bootstrapFlight{done: make(chan struct{})}
	c.flights[flightKey] = flight
	c.mu.Unlock()

	value, err := load(ctx, channel, now)

	c.mu.Lock()
	flight.value = value
	flight.err = err
	if err == nil && c.generations[channel.ID] == flightKey.generation {
		c.entries[key] = bootstrapCacheEntry{
			value:     value,
			expiresAt: now.Add(bootstrapCacheTTL),
		}
	}
	delete(c.flights, flightKey)
	close(flight.done)
	c.mu.Unlock()
	return value, err
}

func (c *bootstrapCache) invalidate(channels []uuid.UUID) {
	if len(channels) == 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, channel := range channels {
		c.generations[channel]++
		for key := range c.entries {
			if key.channelID == channel {
				delete(c.entries, key)
			}
		}
	}
}

func (c *bootstrapCache) pruneExpiredLocked(now time.Time) {
	for key, entry := range c.entries {
		if !entry.expiresAt.After(now) {
			delete(c.entries, key)
		}
	}
}

func newBootstrapCacheKey(channel live.Channel) bootstrapCacheKey {
	key := bootstrapCacheKey{
		channelID: channel.ID,
		policy:    channel.Policy,
	}
	if channel.ActivityID != nil {
		key.activityID = *channel.ActivityID
		key.hasActivity = true
	}
	if channel.Policy == "rounded" && channel.Decimals != nil {
		key.decimals = *channel.Decimals
		key.hasDecimals = true
	}
	return key
}
