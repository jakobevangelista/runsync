package live

import (
	"sync"

	"github.com/google/uuid"
	"github.com/jakobevangelista/runsync/server/internal/telemetry"
)

type Message struct {
	Kind  string
	Event telemetry.Event
}

type Subscription struct {
	C     <-chan Message
	close func()
}

func (s Subscription) Close() { s.close() }

type Hub struct {
	mu       sync.Mutex
	size     int
	next     uint64
	channels map[uuid.UUID]map[uint64]chan Message
}

func NewHub(queueSize int) *Hub {
	if queueSize < 1 {
		queueSize = 1
	}
	return &Hub{size: queueSize, channels: map[uuid.UUID]map[uint64]chan Message{}}
}
func (h *Hub) Subscribe(channel uuid.UUID) Subscription {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.next++
	id := h.next
	c := make(chan Message, h.size)
	if h.channels[channel] == nil {
		h.channels[channel] = map[uint64]chan Message{}
	}
	h.channels[channel][id] = c
	var once sync.Once
	return Subscription{C: c, close: func() {
		once.Do(func() {
			h.mu.Lock()
			defer h.mu.Unlock()
			if subs := h.channels[channel]; subs != nil {
				if existing, ok := subs[id]; ok {
					delete(subs, id)
					close(existing)
				}
				if len(subs) == 0 {
					delete(h.channels, channel)
				}
			}
		})
	}}
}
func (h *Hub) Publish(channel uuid.UUID, message Message) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for id, c := range h.channels[channel] {
		select {
		case c <- message:
		default:
			delete(h.channels[channel], id)
			close(c)
		}
	}
}
func (h *Hub) Count(channel uuid.UUID) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.channels[channel])
}
