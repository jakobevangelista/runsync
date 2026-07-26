package api

import (
	"sync"
	"testing"

	"github.com/google/uuid"
)

func TestSSEConnectionRegistryLimits(t *testing.T) {
	channelA, channelB := uuid.New(), uuid.New()
	tests := []struct {
		name     string
		limits   sseConnectionLimits
		acquires []struct {
			ip      string
			channel uuid.UUID
			ok      bool
		}
	}{
		{
			name:   "per IP",
			limits: sseConnectionLimits{perIP: 2, perChannel: 10, global: 10},
			acquires: []struct {
				ip      string
				channel uuid.UUID
				ok      bool
			}{
				{"198.51.100.1", channelA, true},
				{"198.51.100.1", channelB, true},
				{"198.51.100.1", channelB, false},
				{"198.51.100.2", channelA, true},
			},
		},
		{
			name:   "per channel",
			limits: sseConnectionLimits{perIP: 10, perChannel: 2, global: 10},
			acquires: []struct {
				ip      string
				channel uuid.UUID
				ok      bool
			}{
				{"198.51.100.1", channelA, true},
				{"198.51.100.2", channelA, true},
				{"198.51.100.3", channelA, false},
				{"198.51.100.3", channelB, true},
			},
		},
		{
			name:   "global",
			limits: sseConnectionLimits{perIP: 10, perChannel: 10, global: 2},
			acquires: []struct {
				ip      string
				channel uuid.UUID
				ok      bool
			}{
				{"198.51.100.1", channelA, true},
				{"198.51.100.2", channelB, true},
				{"198.51.100.3", channelB, false},
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			registry := newSSEConnectionRegistryWithLimits(test.limits)
			var releases []func()
			for index, acquire := range test.acquires {
				release, ok := registry.acquire(acquire.ip, acquire.channel)
				if ok != acquire.ok {
					t.Fatalf("acquire %d ok=%v, want %v", index, ok, acquire.ok)
				}
				if ok {
					releases = append(releases, release)
				}
			}
			for _, release := range releases {
				release()
			}
			assertEmptySSERegistry(t, registry)
		})
	}
}

func TestSSEConnectionRegistryRejectsAtomically(t *testing.T) {
	registry := newSSEConnectionRegistryWithLimits(sseConnectionLimits{
		perIP:      1,
		perChannel: 3,
		global:     3,
	})
	channelA, channelB := uuid.New(), uuid.New()
	release, ok := registry.acquire("198.51.100.1", channelA)
	if !ok {
		t.Fatal("initial acquire rejected")
	}
	before := registry.counts()
	if rejectedRelease, accepted := registry.acquire("198.51.100.1", channelB); accepted || rejectedRelease != nil {
		t.Fatal("capacity rejection unexpectedly acquired")
	}
	after := registry.counts()
	if after.total != before.total ||
		after.byIP["198.51.100.1"] != before.byIP["198.51.100.1"] ||
		after.byChannel[channelB] != 0 {
		t.Fatalf("rejection changed counts: before=%#v after=%#v", before, after)
	}
	release()
	release()
	assertEmptySSERegistry(t, registry)
}

func TestSSEConnectionRegistryIsolatesIPsAndChannels(t *testing.T) {
	registry := newSSEConnectionRegistryWithLimits(sseConnectionLimits{
		perIP:      1,
		perChannel: 1,
		global:     4,
	})
	channelA, channelB := uuid.New(), uuid.New()
	releaseA, ok := registry.acquire("198.51.100.1", channelA)
	if !ok {
		t.Fatal("first acquire rejected")
	}
	if _, ok := registry.acquire("198.51.100.2", channelA); ok {
		t.Fatal("channel limit did not isolate the channel")
	}
	if _, ok := registry.acquire("198.51.100.1", channelB); ok {
		t.Fatal("IP limit did not isolate the IP")
	}
	releaseB, ok := registry.acquire("198.51.100.2", channelB)
	if !ok {
		t.Fatal("independent IP and channel rejected")
	}
	releaseA()
	releaseB()
	assertEmptySSERegistry(t, registry)
}

func TestSSEConnectionRegistryConcurrentAcquireAndRelease(t *testing.T) {
	const workers = 200
	registry := newSSEConnectionRegistryWithLimits(sseConnectionLimits{
		perIP:      workers,
		perChannel: workers,
		global:     workers,
	})
	channel := uuid.New()
	start := make(chan struct{})
	var wg sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			release, ok := registry.acquire("198.51.100.1", channel)
			if !ok {
				t.Errorf("concurrent acquire rejected")
				return
			}
			release()
		}()
	}
	close(start)
	wg.Wait()
	assertEmptySSERegistry(t, registry)
}

func assertEmptySSERegistry(t *testing.T, registry *sseConnectionRegistry) {
	t.Helper()
	counts := registry.counts()
	if counts.total != 0 || len(counts.byIP) != 0 || len(counts.byChannel) != 0 {
		t.Fatalf("registry retained counts: %#v", counts)
	}
}
