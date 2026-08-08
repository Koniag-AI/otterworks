package proxy

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"
)

// CircuitState represents the state of a circuit breaker.
type CircuitState int

const (
	StateClosed   CircuitState = iota // normal operation
	StateOpen                         // circuit is open, requests are rejected
	StateHalfOpen                     // allowing probe requests
)

func (s CircuitState) String() string {
	switch s {
	case StateClosed:
		return "closed"
	case StateOpen:
		return "open"
	case StateHalfOpen:
		return "half-open"
	default:
		return "unknown"
	}
}

// CircuitBreakerConfig holds configuration for a circuit breaker.
type CircuitBreakerConfig struct {
	MaxRequests  uint32        // max requests allowed in half-open state
	Interval     time.Duration // cyclic period of the closed state to clear counts
	Timeout      time.Duration // how long to wait before transitioning from open to half-open
	FailureRatio float64       // ratio of failures to total that trips the breaker
}

// CircuitBreaker implements the circuit breaker pattern for a single backend.
type CircuitBreaker struct {
	mu     sync.Mutex
	name   string
	state  CircuitState
	config CircuitBreakerConfig
	counts counts
	expiry time.Time
	now    func() time.Time
}

type counts struct {
	requests             uint32
	totalSuccesses       uint32
	totalFailures        uint32
	consecutiveSuccesses uint32
	consecutiveFailures  uint32
}

func (c *counts) reset() {
	c.requests = 0
	c.totalSuccesses = 0
	c.totalFailures = 0
	c.consecutiveSuccesses = 0
	c.consecutiveFailures = 0
}

func (c *counts) onSuccess() {
	c.totalSuccesses++
	c.consecutiveSuccesses++
	c.consecutiveFailures = 0
}

func (c *counts) onFailure() {
	c.totalFailures++
	c.consecutiveFailures++
	c.consecutiveSuccesses = 0
}

// NewCircuitBreaker creates a new circuit breaker with the given config.
func NewCircuitBreaker(name string, cfg CircuitBreakerConfig) *CircuitBreaker {
	cb := &CircuitBreaker{
		name:   name,
		state:  StateClosed,
		config: cfg,
		now:    time.Now,
	}
	return cb
}

// State returns the current state of the circuit breaker.
func (cb *CircuitBreaker) State() CircuitState {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.currentState()
}

func (cb *CircuitBreaker) currentState() CircuitState {
	now := cb.now()
	switch cb.state {
	case StateClosed:
		if !cb.expiry.IsZero() && cb.expiry.Before(now) {
			cb.toNewGeneration(now)
		}
	case StateOpen:
		if cb.expiry.Before(now) {
			cb.setState(StateHalfOpen, now)
		}
	case StateHalfOpen:
		// Probes get a bounded window to settle. If it elapses without the
		// breaker closing, fall back to open so a fresh round of probes is
		// scheduled instead of the breaker wedging in half-open forever.
		if !cb.expiry.IsZero() && cb.expiry.Before(now) {
			cb.setState(StateOpen, now)
		}
	}
	return cb.state
}

func (cb *CircuitBreaker) setState(state CircuitState, now time.Time) {
	cb.state = state
	cb.counts.reset()

	switch state {
	case StateClosed:
		if cb.config.Interval > 0 {
			cb.expiry = now.Add(cb.config.Interval)
		}
	case StateOpen:
		cb.expiry = now.Add(cb.config.Timeout)
	case StateHalfOpen:
		cb.expiry = now.Add(cb.config.Timeout)
	}
}

func (cb *CircuitBreaker) toNewGeneration(now time.Time) {
	cb.counts.reset()
	if cb.config.Interval > 0 {
		cb.expiry = now.Add(cb.config.Interval)
	} else {
		cb.expiry = time.Time{}
	}
}

// Execute runs the given request through the circuit breaker.
func (cb *CircuitBreaker) Execute(handler http.Handler, w http.ResponseWriter, r *http.Request) error {
	cb.mu.Lock()
	state := cb.currentState()

	if state == StateOpen {
		cb.mu.Unlock()
		return fmt.Errorf("circuit breaker %s is open", cb.name)
	}

	if state == StateHalfOpen && cb.counts.requests >= cb.config.MaxRequests {
		cb.mu.Unlock()
		return fmt.Errorf("circuit breaker %s: too many requests in half-open state", cb.name)
	}

	cb.counts.requests++
	cb.mu.Unlock()

	// Use a response recorder to detect failures
	rec := &statusRecorder{ResponseWriter: w, statusCode: http.StatusOK}

	// Record the outcome even if the handler panics, otherwise the half-open
	// probe slot is consumed permanently and the breaker can never close.
	failed := true
	defer func() {
		cb.mu.Lock()
		defer cb.mu.Unlock()
		if failed {
			cb.onFailure()
			return
		}
		cb.onSuccess()
	}()

	handler.ServeHTTP(rec, r)
	failed = rec.statusCode >= 500

	return nil
}

func (cb *CircuitBreaker) onSuccess() {
	cb.counts.onSuccess()
	if cb.state == StateHalfOpen && cb.counts.consecutiveSuccesses >= cb.config.MaxRequests {
		cb.setState(StateClosed, cb.now())
	}
}

func (cb *CircuitBreaker) onFailure() {
	cb.counts.onFailure()
	now := cb.now()
	switch cb.state {
	case StateClosed:
		if cb.shouldTrip() {
			cb.setState(StateOpen, now)
		}
	case StateHalfOpen:
		cb.setState(StateOpen, now)
	}
}

func (cb *CircuitBreaker) shouldTrip() bool {
	total := cb.counts.totalSuccesses + cb.counts.totalFailures
	if total < 5 { // minimum sample size
		return false
	}
	ratio := float64(cb.counts.totalFailures) / float64(total)
	return ratio >= cb.config.FailureRatio
}

// statusRecorder wraps http.ResponseWriter to capture the status code.
type statusRecorder struct {
	http.ResponseWriter
	statusCode int
	written    bool
}

func (r *statusRecorder) WriteHeader(code int) {
	if !r.written {
		r.statusCode = code
		r.written = true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if !r.written {
		r.written = true
	}
	return r.ResponseWriter.Write(b)
}

func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}

func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hijacker, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("wrapped response writer does not support hijacking")
	}
	return hijacker.Hijack()
}

// CircuitBreakerManager manages circuit breakers for multiple backends.
type CircuitBreakerManager struct {
	mu       sync.RWMutex
	breakers map[string]*CircuitBreaker
	config   CircuitBreakerConfig
}

// NewCircuitBreakerManager creates a new manager with the given default config.
func NewCircuitBreakerManager(cfg CircuitBreakerConfig) *CircuitBreakerManager {
	return &CircuitBreakerManager{
		breakers: make(map[string]*CircuitBreaker),
		config:   cfg,
	}
}

// Get returns the circuit breaker for the given backend, creating one if needed.
func (m *CircuitBreakerManager) Get(name string) *CircuitBreaker {
	m.mu.RLock()
	cb, ok := m.breakers[name]
	m.mu.RUnlock()
	if ok {
		return cb
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	// Double-check after acquiring write lock
	if cb, ok = m.breakers[name]; ok {
		return cb
	}
	cb = NewCircuitBreaker(name, m.config)
	m.breakers[name] = cb
	return cb
}
