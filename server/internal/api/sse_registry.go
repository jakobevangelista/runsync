package api

import (
	"sync"

	"github.com/google/uuid"
)

const (
	// These are resource ceilings for a deployment target of 100 legitimate
	// viewers, not user authentication or complete DDoS protection. The channel
	// limit allows reconnect and operational headroom, the global limit prevents
	// unbounded socket and goroutine consumption, and the IP limit slows
	// single-origin abuse while remaining high enough for shared household
	// networks.
	maxSSEConnectionsPerIP      = 50
	maxSSEConnectionsPerChannel = 150
	maxSSEConnectionsGlobal     = 200
)

type sseConnectionLimits struct {
	perIP      int
	perChannel int
	global     int
}

type sseConnectionRegistry struct {
	mu        sync.Mutex
	limits    sseConnectionLimits
	total     int
	byIP      map[string]int
	byChannel map[uuid.UUID]int
}

func newSSEConnectionRegistry() *sseConnectionRegistry {
	return newSSEConnectionRegistryWithLimits(sseConnectionLimits{
		perIP:      maxSSEConnectionsPerIP,
		perChannel: maxSSEConnectionsPerChannel,
		global:     maxSSEConnectionsGlobal,
	})
}

func newSSEConnectionRegistryWithLimits(limits sseConnectionLimits) *sseConnectionRegistry {
	return &sseConnectionRegistry{
		limits:    limits,
		byIP:      map[string]int{},
		byChannel: map[uuid.UUID]int{},
	}
}

func (r *sseConnectionRegistry) acquire(ip string, channel uuid.UUID) (func(), bool) {
	r.mu.Lock()
	if r.total >= r.limits.global ||
		r.byIP[ip] >= r.limits.perIP ||
		r.byChannel[channel] >= r.limits.perChannel {
		r.mu.Unlock()
		return nil, false
	}
	r.total++
	r.byIP[ip]++
	r.byChannel[channel]++
	r.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.total--
			if r.byIP[ip]--; r.byIP[ip] == 0 {
				delete(r.byIP, ip)
			}
			if r.byChannel[channel]--; r.byChannel[channel] == 0 {
				delete(r.byChannel, channel)
			}
		})
	}, true
}

type sseConnectionCounts struct {
	total     int
	byIP      map[string]int
	byChannel map[uuid.UUID]int
}

func (r *sseConnectionRegistry) counts() sseConnectionCounts {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := sseConnectionCounts{
		total:     r.total,
		byIP:      make(map[string]int, len(r.byIP)),
		byChannel: make(map[uuid.UUID]int, len(r.byChannel)),
	}
	for ip, count := range r.byIP {
		out.byIP[ip] = count
	}
	for channel, count := range r.byChannel {
		out.byChannel[channel] = count
	}
	return out
}
