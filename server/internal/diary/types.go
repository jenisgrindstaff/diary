package diary

import (
	"strings"
	"time"
)

type Entry struct {
	ID             string          `json:"id" yaml:"id"`
	CreatedAt      time.Time       `json:"created_at" yaml:"created_at"`
	UpdatedAt      time.Time       `json:"updated_at" yaml:"updated_at"`
	ServerRevision string          `json:"server_revision" yaml:"revision"`
	Title          string          `json:"title" yaml:"title"`
	Excerpt        string          `json:"excerpt" yaml:"excerpt"`
	BodyMarkdown   string          `json:"body_markdown" yaml:"-"`
	SourcePath     string          `json:"source_path" yaml:"source_path"`
	Tags           []string        `json:"tags" yaml:"tags"`
	People         []string        `json:"people" yaml:"people"`
	SubjectDetails []SubjectDetail `json:"subject_details" yaml:"subject_details"`
	Attachments    []Attachment    `json:"attachments" yaml:"attachments"`
	Context        EntryContext    `json:"context" yaml:"context,omitempty"`
	VaultPath      string          `json:"-" yaml:"-"`
}

type SubjectDetail struct {
	Name    string `json:"name" yaml:"name"`
	Label   string `json:"label,omitempty" yaml:"label,omitempty"`
	AgeText string `json:"age_text,omitempty" yaml:"age_text,omitempty"`
	RawText string `json:"raw_text,omitempty" yaml:"raw_text,omitempty"`
}

type Attachment struct {
	ID           string     `json:"id" yaml:"id"`
	Kind         string     `json:"kind" yaml:"kind"`
	Filename     string     `json:"filename" yaml:"filename"`
	ContentType  string     `json:"content_type" yaml:"content_type"`
	RemotePath   string     `json:"remote_path" yaml:"remote_path"`
	MarkdownPath string     `json:"markdown_path" yaml:"markdown_path"`
	ByteCount    int64      `json:"byte_count" yaml:"byte_count"`
	Width        *int       `json:"width,omitempty" yaml:"width,omitempty"`
	Height       *int       `json:"height,omitempty" yaml:"height,omitempty"`
	CreatedAt    *time.Time `json:"created_at,omitempty" yaml:"created_at,omitempty"`
	AbsolutePath string     `json:"-" yaml:"-"`
}

type EntryContext struct {
	Location *LocationContext `json:"location,omitempty" yaml:"location,omitempty"`
	Weather  *WeatherContext  `json:"weather,omitempty" yaml:"weather,omitempty"`
	Activity *ActivityContext `json:"activity,omitempty" yaml:"activity,omitempty"`
	Source   string           `json:"source,omitempty" yaml:"source,omitempty"`
}

func (c EntryContext) IsZero() bool {
	return c.Location == nil && c.Weather == nil && c.Activity == nil && c.Source == ""
}

func (c EntryContext) SearchText() string {
	values := []string{c.Source}
	if c.Location != nil {
		values = append(values, c.Location.Label, c.Location.Precision)
	}
	if c.Weather != nil {
		values = append(values, c.Weather.Provider, c.Weather.Condition, c.Weather.Symbol, c.Weather.Precipitation, c.Weather.Attribution)
		if c.Weather.TemperatureF != nil {
			values = append(values, "temperature")
		}
		if c.Weather.WindMph != nil {
			values = append(values, "wind")
		}
	}
	if c.Activity != nil {
		values = append(values, "activity", "steps", "exercise")
		for _, workout := range c.Activity.Workouts {
			values = append(values, workout.Type)
		}
	}
	return strings.Join(values, " ")
}

type LocationContext struct {
	Label      string     `json:"label,omitempty" yaml:"label,omitempty"`
	Latitude   *float64   `json:"latitude,omitempty" yaml:"latitude,omitempty"`
	Longitude  *float64   `json:"longitude,omitempty" yaml:"longitude,omitempty"`
	Precision  string     `json:"precision,omitempty" yaml:"precision,omitempty"`
	CapturedAt *time.Time `json:"captured_at,omitempty" yaml:"captured_at,omitempty"`
}

type WeatherContext struct {
	Provider      string     `json:"provider,omitempty" yaml:"provider,omitempty"`
	Condition     string     `json:"condition,omitempty" yaml:"condition,omitempty"`
	Symbol        string     `json:"symbol,omitempty" yaml:"symbol,omitempty"`
	TemperatureF  *float64   `json:"temperature_f,omitempty" yaml:"temperature_f,omitempty"`
	Precipitation string     `json:"precipitation,omitempty" yaml:"precipitation,omitempty"`
	WindMph       *float64   `json:"wind_mph,omitempty" yaml:"wind_mph,omitempty"`
	Attribution   string     `json:"attribution,omitempty" yaml:"attribution,omitempty"`
	FetchedAt     *time.Time `json:"fetched_at,omitempty" yaml:"fetched_at,omitempty"`
}

type ActivityContext struct {
	Steps            *int             `json:"steps,omitempty" yaml:"steps,omitempty"`
	ExerciseMinutes  *int             `json:"exercise_minutes,omitempty" yaml:"exercise_minutes,omitempty"`
	ActiveEnergyKcal *float64         `json:"active_energy_kcal,omitempty" yaml:"active_energy_kcal,omitempty"`
	Workouts         []WorkoutContext `json:"workouts,omitempty" yaml:"workouts,omitempty"`
	CapturedAt       *time.Time       `json:"captured_at,omitempty" yaml:"captured_at,omitempty"`
}

type WorkoutContext struct {
	Type             string     `json:"type,omitempty" yaml:"type,omitempty"`
	StartAt          *time.Time `json:"start_at,omitempty" yaml:"start_at,omitempty"`
	EndAt            *time.Time `json:"end_at,omitempty" yaml:"end_at,omitempty"`
	DurationMinutes  *float64   `json:"duration_minutes,omitempty" yaml:"duration_minutes,omitempty"`
	DistanceMiles    *float64   `json:"distance_miles,omitempty" yaml:"distance_miles,omitempty"`
	ActiveEnergyKcal *float64   `json:"active_energy_kcal,omitempty" yaml:"active_energy_kcal,omitempty"`
}

type Tombstone struct {
	EntryID    string    `json:"entry_id" yaml:"entry_id"`
	DeletedAt  time.Time `json:"deleted_at" yaml:"deleted_at"`
	SourcePath string    `json:"source_path" yaml:"source_path"`
	TrashPath  string    `json:"trash_path" yaml:"trash_path"`
}
