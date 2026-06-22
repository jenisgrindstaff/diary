package store

import (
	"database/sql"
	"errors"
	"time"
)

type SyncDevice struct {
	DeviceID       string    `json:"device_id"`
	DisplayName    string    `json:"display_name"`
	Platform       string    `json:"platform"`
	AppVersion     string    `json:"app_version"`
	RegisteredAt   time.Time `json:"registered_at"`
	LastSeenAt     time.Time `json:"last_seen_at"`
	LastSyncCursor string    `json:"last_sync_cursor"`
}

func (s *Store) RegisterDevice(device SyncDevice, tokenHash string, now time.Time) (SyncDevice, error) {
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}
	if device.RegisteredAt.IsZero() {
		device.RegisteredAt = now
	}
	device.RegisteredAt = device.RegisteredAt.UTC()
	device.LastSeenAt = now

	_, err := s.db.Exec(`
INSERT INTO sync_devices (device_id, display_name, platform, app_version, token_hash, registered_at, last_seen_at, last_sync_cursor)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(device_id) DO UPDATE SET
	display_name = excluded.display_name,
	platform = excluded.platform,
	app_version = excluded.app_version,
	token_hash = excluded.token_hash,
	last_seen_at = excluded.last_seen_at`,
		device.DeviceID,
		device.DisplayName,
		device.Platform,
		device.AppVersion,
		tokenHash,
		device.RegisteredAt.Format(time.RFC3339Nano),
		device.LastSeenAt.Format(time.RFC3339Nano),
		device.LastSyncCursor,
	)
	if err != nil {
		return SyncDevice{}, err
	}

	return s.Device(device.DeviceID)
}

func (s *Store) Device(deviceID string) (SyncDevice, error) {
	row := s.db.QueryRow(`
SELECT device_id, display_name, platform, app_version, registered_at, last_seen_at, last_sync_cursor
FROM sync_devices
WHERE device_id = ?`, deviceID)
	return scanDevice(row)
}

func (s *Store) DeviceByTokenHash(tokenHash string) (SyncDevice, error) {
	row := s.db.QueryRow(`
SELECT device_id, display_name, platform, app_version, registered_at, last_seen_at, last_sync_cursor
FROM sync_devices
WHERE token_hash = ?`, tokenHash)
	device, err := scanDevice(row)
	if errors.Is(err, sql.ErrNoRows) {
		return SyncDevice{}, err
	}
	return device, err
}

func (s *Store) TouchDevice(deviceID string, now time.Time) error {
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}

	_, err := s.db.Exec(`
UPDATE sync_devices
SET last_seen_at = ?
WHERE device_id = ?`,
		now.Format(time.RFC3339Nano),
		deviceID,
	)
	return err
}

func (s *Store) UpdateDeviceSyncCursor(deviceID string, cursor string, now time.Time) error {
	if now.IsZero() {
		now = time.Now().UTC()
	} else {
		now = now.UTC()
	}

	_, err := s.db.Exec(`
UPDATE sync_devices
SET last_sync_cursor = ?, last_seen_at = ?
WHERE device_id = ?`,
		cursor,
		now.Format(time.RFC3339Nano),
		deviceID,
	)
	return err
}

func scanDevice(row rowScanner) (SyncDevice, error) {
	var device SyncDevice
	var registeredAt string
	var lastSeenAt string
	if err := row.Scan(
		&device.DeviceID,
		&device.DisplayName,
		&device.Platform,
		&device.AppVersion,
		&registeredAt,
		&lastSeenAt,
		&device.LastSyncCursor,
	); err != nil {
		return SyncDevice{}, err
	}

	device.RegisteredAt, _ = time.Parse(time.RFC3339Nano, registeredAt)
	device.LastSeenAt, _ = time.Parse(time.RFC3339Nano, lastSeenAt)
	return device, nil
}
