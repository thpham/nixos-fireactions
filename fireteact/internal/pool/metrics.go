// Package pool provides pool management metrics for fireteact runners.
package pool

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

const (
	namespace = "fireteact"
)

var (
	// Server metrics
	metricUp = promauto.NewGauge(prometheus.GaugeOpts{
		Name:      "up",
		Namespace: namespace,
		Subsystem: "server",
		Help:      "Is the server up",
	})

	// Pool metrics
	metricPoolMaxRunnersCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name:      "max_runners_count",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Maximum number of runners in a pool",
	}, []string{"pool"})

	metricPoolMinRunnersCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name:      "min_runners_count",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Minimum number of runners in a pool",
	}, []string{"pool"})

	metricPoolCurrentRunnersCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name:      "current_runners_count",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Current number of runners in a pool",
	}, []string{"pool"})

	metricPoolIdleRunnersCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name:      "idle_runners_count",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Current number of idle runners in a pool",
	}, []string{"pool"})

	metricPoolBusyRunnersCount = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name:      "busy_runners_count",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Current number of busy runners in a pool",
	}, []string{"pool"})

	metricPoolScaleRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name:      "scale_requests_total",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Total number of scale requests for a pool",
	}, []string{"pool"})

	metricPoolScaleFailures = promauto.NewCounterVec(prometheus.CounterOpts{
		Name:      "scale_failures_total",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Total number of scale failures for a pool",
	}, []string{"pool"})

	metricPoolScaleSuccesses = promauto.NewCounterVec(prometheus.CounterOpts{
		Name:      "scale_successes_total",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Total number of scale successes for a pool",
	}, []string{"pool"})

	metricPoolTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Name:      "total",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Total number of pools",
	})

	metricPoolStatus = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name:      "status",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Status of a pool. 0 is paused, 1 is active.",
	}, []string{"pool"})

	// VM metrics
	metricVMCreationDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:      "vm_creation_duration_seconds",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Time taken to create a VM",
		Buckets:   prometheus.DefBuckets,
	}, []string{"pool"})

	metricVMLifetimeDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:      "vm_lifetime_duration_seconds",
		Namespace: namespace,
		Subsystem: "pool",
		Help:      "Lifetime of a VM from creation to destruction",
		Buckets:   []float64{60, 300, 600, 1800, 3600, 7200, 14400},
	}, []string{"pool"})
)

// SetServerUp marks the server as up.
func SetServerUp() {
	metricUp.Set(1)
}

// SetServerDown marks the server as down.
func SetServerDown() {
	metricUp.Set(0)
}
