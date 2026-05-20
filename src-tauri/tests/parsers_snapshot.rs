//! Integration snapshot tests for the agent parsers.
//!
//! Each test materializes a minimal on-disk fixture under a `tempfile::tempdir`,
//! constructs the parser with `with_base_dir(...)`, and compares the
//! `list_conversations` + `get_conversation` outputs against committed `.snap`
//! files via `insta::assert_json_snapshot!`.
//!
//! Why redact timestamps: a few parser code paths fall back to `Utc::now()` when
//! a JSON value is missing a timestamp. Redacting `started_at`/`ended_at`/
//! `timestamp`/`completed_at` everywhere keeps snapshots stable even if such a
//! fallback fires unexpectedly.

use std::fs;
use std::path::{Path, PathBuf};

use codeg_lib::parsers::{
    claude::ClaudeParser, cline::ClineParser, codex::CodexParser, gemini::GeminiParser,
    openclaw::OpenClawParser, opencode::OpenCodeParser, AgentParser,
};
use insta::assert_json_snapshot;
use serde_json::json;

fn write(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent dir");
    }
    fs::write(path, contents).expect("write fixture file");
}

// ────────────────────────────────────────────────────────────────────────────
// Claude
// ────────────────────────────────────────────────────────────────────────────

#[test]
fn claude_minimal_session_snapshot() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let base = temp.path().to_path_buf();
    // Claude stores conversations under `<base>/<encoded-folder>/<id>.jsonl`.
    let project_dir = base.join("-tmp-demo");
    let session_id = "claude-sess-001";
    let jsonl = format!(
        "{}\n{}\n",
        json!({
            "type": "user",
            "sessionId": session_id,
            "timestamp": "2026-03-01T10:00:00Z",
            "uuid": "u1",
            "cwd": "/tmp/demo",
            "gitBranch": "main",
            "message": { "content": [{"type": "text", "text": "hello"}] }
        }),
        json!({
            "type": "assistant",
            "sessionId": session_id,
            "timestamp": "2026-03-01T10:00:02Z",
            "uuid": "a1",
            "message": {
                "model": "claude-sonnet-4-6",
                "content": [{"type": "text", "text": "world"}],
                "usage": {
                    "input_tokens": 1000,
                    "output_tokens": 200,
                    "cache_creation_input_tokens": 300,
                    "cache_read_input_tokens": 400
                }
            }
        }),
    );
    write(&project_dir.join(format!("{session_id}.jsonl")), &jsonl);

    let parser = ClaudeParser::with_base_dir(base);
    let summaries = parser.list_conversations().expect("list claude");
    let detail = parser.get_conversation(session_id).expect("detail claude");

    assert_json_snapshot!("claude_list", summaries, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
    });
    assert_json_snapshot!("claude_detail", detail, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
        ".**.timestamp" => "[ts]",
        ".**.completed_at" => "[ts]",
    });
}

// ────────────────────────────────────────────────────────────────────────────
// Codex
// ────────────────────────────────────────────────────────────────────────────

#[test]
fn codex_minimal_session_snapshot() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let base = temp.path().to_path_buf();
    let session_id = "codex-sess-001";
    // Codex walks `<base>/**/*.jsonl` and requires the filename to start with
    // `rollout-` (real Codex CLI naming convention) for both list and detail.
    let jsonl_path = base
        .join("2026")
        .join("03")
        .join(format!("rollout-{session_id}.jsonl"));
    let jsonl = format!(
        "{}\n{}\n{}\n{}\n",
        json!({
            "timestamp": "2026-03-01T10:00:00Z",
            "type": "session_meta",
            "payload": {
                "id": session_id,
                "cwd": "/tmp/demo",
                "cli_version": "0.1.0",
                "git": {"branch": "main"}
            }
        }),
        json!({
            "timestamp": "2026-03-01T10:00:00.500Z",
            "type": "turn_context",
            "payload": {"model": "gpt-5.1-codex"}
        }),
        json!({
            "timestamp": "2026-03-01T10:00:01Z",
            "type": "event_msg",
            "payload": {"type": "user_message", "message": "ping"}
        }),
        json!({
            "timestamp": "2026-03-01T10:00:02Z",
            "type": "event_msg",
            "payload": {"type": "agent_message", "message": "pong"}
        }),
    );
    write(&jsonl_path, &jsonl);

    let parser = CodexParser::with_base_dir(base);
    let summaries = parser.list_conversations().expect("list codex");
    let detail = parser.get_conversation(session_id).expect("detail codex");

    assert_json_snapshot!("codex_list", summaries, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
    });
    assert_json_snapshot!("codex_detail", detail, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
        ".**.timestamp" => "[ts]",
        ".**.completed_at" => "[ts]",
    });
}

// ────────────────────────────────────────────────────────────────────────────
// Gemini
// ────────────────────────────────────────────────────────────────────────────

#[test]
fn gemini_minimal_session_snapshot() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let base = temp.path().to_path_buf();
    // Gemini layout: <base>/tmp/<project>/chats/session-*.json + .project_root
    let project_dir = base.join("tmp").join("codeg");
    let chats_dir = project_dir.join("chats");
    write(
        &project_dir.join(".project_root"),
        "/Users/test/workspace/demo",
    );
    let session_id = "gemini-sess-001";
    let content = serde_json::to_string_pretty(&json!({
        "sessionId": session_id,
        "projectHash": "abc",
        "startTime": "2026-03-02T04:30:00.000Z",
        "lastUpdated": "2026-03-02T04:30:02.000Z",
        "messages": [
            {
                "id": "u1",
                "timestamp": "2026-03-02T04:30:00.000Z",
                "type": "user",
                "content": [{"text": "ping"}]
            },
            {
                "id": "a1",
                "timestamp": "2026-03-02T04:30:02.000Z",
                "type": "gemini",
                "content": "pong",
                "tokens": {"input": 10, "output": 20, "cached": 3},
                "model": "gemini-2.5-pro"
            }
        ]
    }))
    .expect("serialize gemini fixture");
    write(
        &chats_dir.join(format!("session-2026-03-02T04-30-{session_id}.json")),
        &content,
    );

    let parser = GeminiParser::with_base_dir(base);
    let summaries = parser.list_conversations().expect("list gemini");
    let detail = parser.get_conversation(session_id).expect("detail gemini");

    assert_json_snapshot!("gemini_list", summaries, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
    });
    assert_json_snapshot!("gemini_detail", detail, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
        ".**.timestamp" => "[ts]",
        ".**.completed_at" => "[ts]",
    });
}

// ────────────────────────────────────────────────────────────────────────────
// OpenClaw
// ────────────────────────────────────────────────────────────────────────────

#[test]
fn openclaw_minimal_session_snapshot() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let base = temp.path().to_path_buf();
    // Layout: <base>/<agent_id>/sessions/<session_id>.jsonl
    let agent_id = "test-agent";
    let session_id = "openclaw-sess-001";
    let conversation_id = format!("{agent_id}/{session_id}");
    let sessions_dir = base.join(agent_id).join("sessions");
    let jsonl = format!(
        "{}\n{}\n{}\n",
        json!({
            "type": "session",
            "version": 3,
            "id": session_id,
            "timestamp": "2026-03-17T01:00:00.000Z",
            "cwd": "/tmp/demo"
        }),
        json!({
            "type": "message",
            "id": "u1",
            "parentId": null,
            "timestamp": "2026-03-17T01:00:01.000Z",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": "Hello"}]
            }
        }),
        json!({
            "type": "message",
            "id": "a1",
            "parentId": "u1",
            "timestamp": "2026-03-17T01:00:02.000Z",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "Hi"}],
                "model": "gpt-5.4",
                "usage": {"input": 100, "output": 50, "cacheRead": 200, "cacheWrite": 0, "totalTokens": 350}
            }
        }),
    );
    write(&sessions_dir.join(format!("{session_id}.jsonl")), &jsonl);

    let parser = OpenClawParser::with_base_dir(base);
    let summaries = parser.list_conversations().expect("list openclaw");
    let detail = parser
        .get_conversation(&conversation_id)
        .expect("detail openclaw");

    assert_json_snapshot!("openclaw_list", summaries, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
    });
    assert_json_snapshot!("openclaw_detail", detail, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
        ".**.timestamp" => "[ts]",
        ".**.completed_at" => "[ts]",
    });
}

// ────────────────────────────────────────────────────────────────────────────
// Cline
// ────────────────────────────────────────────────────────────────────────────

#[test]
fn cline_minimal_session_snapshot() {
    let temp = tempfile::tempdir().expect("create tempdir");
    let base = temp.path().to_path_buf();
    // Layout:
    //   <base>/state/taskHistory.json
    //   <base>/tasks/<id>/api_conversation_history.json
    //   <base>/tasks/<id>/task_metadata.json  (optional)
    //
    // Note: started_at is derived by parsing the entry id as a unix-ms
    // timestamp, so use a real timestamp string here.
    let task_id = "1740825600000"; // 2026-03-01T08:00:00Z in ms
    let history = json!([
        {
            "id": task_id,
            "ts": 1_740_825_602_000_i64,
            "task": "ping",
            "tokensIn": 10,
            "tokensOut": 20,
            "totalCost": 0.0,
            "cwdOnTaskInitialization": "/tmp/demo",
            "modelId": "claude-sonnet-4-6"
        }
    ]);
    write(
        &base.join("state").join("taskHistory.json"),
        &serde_json::to_string(&history).unwrap(),
    );

    let api_history = json!([
        {
            "role": "user",
            "content": [{"type": "text", "text": "ping"}],
            "ts": 1_740_825_600_500_i64
        },
        {
            "role": "assistant",
            "content": [{"type": "text", "text": "pong"}],
            "ts": 1_740_825_601_500_i64,
            "modelInfo": {"modelId": "claude-sonnet-4-6"},
            "metrics": {"tokens": {"prompt": 10, "completion": 20, "cached": 3}}
        }
    ]);
    write(
        &base
            .join("tasks")
            .join(task_id)
            .join("api_conversation_history.json"),
        &serde_json::to_string(&api_history).unwrap(),
    );

    let parser = ClineParser::with_base_dir(base);
    let summaries = parser.list_conversations().expect("list cline");
    let detail = parser.get_conversation(task_id).expect("detail cline");

    assert_json_snapshot!("cline_list", summaries, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
    });
    assert_json_snapshot!("cline_detail", detail, {
        ".**.started_at" => "[ts]",
        ".**.ended_at" => "[ts]",
        ".**.timestamp" => "[ts]",
        ".**.completed_at" => "[ts]",
    });
}

// ────────────────────────────────────────────────────────────────────────────
// OpenCode — placeholder
// ────────────────────────────────────────────────────────────────────────────

/// OpenCode reads from a SeaORM-managed SQLite file. Generating a deterministic
/// fixture `opencode.db` requires running the OpenCode-side migrations against
/// an empty in-memory database and committing the resulting binary, or
/// scripting it at test setup time. Out of scope for the first snapshot pass —
/// tracked as a follow-up so that we don't block the other 5 parsers on it.
#[test]
#[ignore = "TODO: requires SeaORM-seeded opencode.db fixture; see plan Phase 2"]
fn opencode_minimal_session_snapshot() {
    let _ = OpenCodeParser::with_base_dir(PathBuf::from("/dev/null"));
}
