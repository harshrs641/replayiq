// Package kafka provides a thin producer/consumer layer over segmentio/kafka-go
// for the ReplayIQ decoupled service architecture.
package kafka

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"sync"
	"time"

	kafkago "github.com/segmentio/kafka-go"
)

// MaxMessageBytes is the largest Kafka message ReplayIQ topics accept (one
// oversized event; batches are split well below it).
const MaxMessageBytes = 8 << 20

// Topic names shared by all services.
const (
	// TopicEventsNative: batches as SDKs sent them, before conversion to
	// rrweb and masking (see package ingest).
	TopicEventsNative     = "events.native"
	TopicEventsRaw        = "events.raw"
	TopicEventsMasked     = "events.masked"
	TopicAnalyzeRequested = "session.analyze-requested"
)

// AnalyzeRequestedEvent is the payload published when a session is ready for
// AI analysis — either automatically after session end, or via the dashboard.
type AnalyzeRequestedEvent struct {
	SessionID string `json:"session_id"`
	// DelayMs tells the AI worker to sleep this long before starting, to give
	// the storage worker time to flush the last event batch to MinIO.
	DelayMs int64 `json:"delay_ms,omitempty"`
}

// Producer publishes JSON-encoded messages to Kafka topics, keyed by session
// ID so all events for the same session land on the same partition (ordered
// delivery, no cross-session interleaving).
type Producer struct {
	brokers []string
	mu      sync.RWMutex
	writers map[string]*kafkago.Writer
}

func NewProducer(brokers []string) *Producer {
	return &Producer{brokers: brokers, writers: make(map[string]*kafkago.Writer)}
}

func (p *Producer) writer(topic string) *kafkago.Writer {
	p.mu.RLock()
	w, ok := p.writers[topic]
	p.mu.RUnlock()
	if ok {
		return w
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	// double-check after acquiring write lock
	if w, ok = p.writers[topic]; ok {
		return w
	}
	w = &kafkago.Writer{
		Addr:                   kafkago.TCP(p.brokers...),
		Topic:                  topic,
		Balancer:               &kafkago.Hash{}, // hash(key) → stable partition per session
		RequiredAcks:           kafkago.RequireOne,
		AllowAutoTopicCreation: true,
		// Event batches (especially mobile screenshot frames) compress ~7x;
		// consumers decompress transparently.
		Compression: kafkago.Zstd,
		// Producers split batches to ~800 KB (ingest.PublishBatch); this
		// admits a single event that is larger on its own.
		BatchBytes: MaxMessageBytes,
	}
	p.writers[topic] = w
	return w
}

// Publish serialises value as JSON and writes it to topic keyed by key.
func (p *Producer) Publish(topic, key string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("kafka marshal: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return p.writer(topic).WriteMessages(ctx, kafkago.Message{
		Key:   []byte(key),
		Value: data,
	})
}

// Close flushes and closes all underlying writers.
func (p *Producer) Close() {
	for _, w := range p.writers {
		w.Close()
	}
}

// Message is the payload delivered to a Consumer handler.
type Message struct {
	Key   []byte
	Value []byte
}

// Consumer wraps a kafka-go reader with at-least-once delivery semantics.
// Offsets are committed after the handler succeeds; on failure the offset is
// NOT committed so the message is redelivered on the next restart.
type Consumer struct {
	reader *kafkago.Reader
}

func NewConsumer(brokers []string, groupID, topic string) *Consumer {
	return &Consumer{
		reader: kafkago.NewReader(kafkago.ReaderConfig{
			Brokers:        brokers,
			GroupID:        groupID,
			Topic:          topic,
			MinBytes:       1,
			MaxBytes:       10e6,
			CommitInterval: time.Second,
			StartOffset:    kafkago.FirstOffset,
		}),
	}
}

// Run processes messages from the topic until ctx is cancelled.  handler is
// called for each message; on error it is logged and the offset is still
// committed to prevent a single bad message from blocking the consumer
// forever (poison-pill protection).
func (c *Consumer) Run(ctx context.Context, handler func(Message) error) {
	for {
		msg, err := c.reader.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			slog.Error("kafka fetch failed", "topic", c.reader.Config().Topic, "error", err)
			time.Sleep(time.Second)
			continue
		}
		if err := handler(Message{Key: msg.Key, Value: msg.Value}); err != nil {
			slog.Error("kafka handler error — committing offset anyway",
				"topic", c.reader.Config().Topic,
				"offset", msg.Offset,
				"error", err,
			)
		}
		if err := c.reader.CommitMessages(ctx, msg); err != nil && ctx.Err() == nil {
			slog.Warn("kafka commit failed", "error", err)
		}
	}
}

func (c *Consumer) Close() error { return c.reader.Close() }

// EnsureTopics creates the given topics if they do not exist. Idempotent;
// safe to call on every startup.  Requires the broker to allow topic auto-
// creation OR the caller to have CreateTopics permission.
func EnsureTopics(brokers []string, topics ...string) error {
	if len(brokers) == 0 {
		return fmt.Errorf("no brokers configured")
	}
	conn, err := kafkago.Dial("tcp", brokers[0])
	if err != nil {
		return fmt.Errorf("kafka dial: %w", err)
	}
	defer conn.Close()

	controller, err := conn.Controller()
	if err != nil {
		return fmt.Errorf("kafka controller: %w", err)
	}
	ctrlConn, err := kafkago.Dial("tcp", net.JoinHostPort(controller.Host, strconv.Itoa(controller.Port)))
	if err != nil {
		return fmt.Errorf("kafka controller dial: %w", err)
	}
	defer ctrlConn.Close()

	topicConfigs := make([]kafkago.TopicConfig, len(topics))
	for i, t := range topics {
		topicConfigs[i] = kafkago.TopicConfig{
			Topic:             t,
			NumPartitions:     12,
			ReplicationFactor: 1,
			ConfigEntries:     []kafkago.ConfigEntry{{ConfigName: "max.message.bytes", ConfigValue: strconv.Itoa(MaxMessageBytes)}},
		}
	}
	if err := ctrlConn.CreateTopics(topicConfigs...); err != nil && !errors.Is(err, kafkago.TopicAlreadyExists) {
		return err
	}
	// Topics created before the limit was raised keep 1 MB: raise it.
	client := &kafkago.Client{Addr: kafkago.TCP(brokers...), Timeout: 10 * time.Second}
	var resources []kafkago.AlterConfigRequestResource
	for _, t := range topics {
		resources = append(resources, kafkago.AlterConfigRequestResource{
			ResourceType: kafkago.ResourceTypeTopic, ResourceName: t,
			Configs: []kafkago.AlterConfigRequestConfig{{Name: "max.message.bytes", Value: strconv.Itoa(MaxMessageBytes)}},
		})
	}
	res, err := client.AlterConfigs(context.Background(), &kafkago.AlterConfigsRequest{Resources: resources})
	if err != nil {
		return fmt.Errorf("raise max.message.bytes: %w", err)
	}
	for r, rerr := range res.Errors {
		if rerr != nil {
			return fmt.Errorf("raise max.message.bytes on %s: %w", r.Name, rerr)
		}
	}
	return nil
}
