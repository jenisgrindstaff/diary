package diary

import "time"

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

type Tombstone struct {
	EntryID    string    `json:"entry_id" yaml:"entry_id"`
	DeletedAt  time.Time `json:"deleted_at" yaml:"deleted_at"`
	SourcePath string    `json:"source_path" yaml:"source_path"`
	TrashPath  string    `json:"trash_path" yaml:"trash_path"`
}
