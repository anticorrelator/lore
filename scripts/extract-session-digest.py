#!/usr/bin/env python3
"""
Extract a lightweight digest from the last Claude Code session's JSONL transcript.
Runs during SessionStart hook and writes _pending_digest.md for LLM processing.
"""

import argparse
import json
import os
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

# Shared transcript infrastructure
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transcript import resolve_knowledge_dir as _resolve_knowledge_dir


# Common stopwords to filter out from topic detection
STOPWORDS = {
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'to', 'of', 'in', 'for', 'on',
    'with', 'that', 'this', 'it', 'and', 'or', 'but', 'not', 'you', 'we', 'i',
    'my', 'your', 'our', 'can', 'do', 'how', 'what', 'be', 'at', 'by', 'from',
    'as', 'if', 'all', 'so', 'will', 'has', 'have', 'had', 'would', 'could',
    'should', 'their', 'there', 'when', 'where', 'which', 'who', 'why', 'am',
    'me', 'him', 'her', 'his', 'its', 'us', 'them', 'than', 'then', 'now',
    'out', 'up', 'down', 'any', 'some', 'no', 'yes', 'more', 'most', 'just',
    'only', 'other', 'into', 'over', 'after', 'before', 'these', 'those',
    'been', 'being', 'does', 'did', 'done', 'doing', 'about', 'get', 'got',
    'make', 'made', 'use', 'used', 'like', 'need', 'see', 'know', 'think',
}


def extract_text_from_content(content):
    """Extract text from message content (handles both string and array formats)."""
    if isinstance(content, str):
        return content
    elif isinstance(content, list):
        texts = []
        for item in content:
            if isinstance(item, dict) and item.get('type') == 'text':
                texts.append(item.get('text', ''))
        return ' '.join(texts)
    return ''


def parse_jsonl_file(jsonl_path, max_lines=300):
    """Parse JSONL file and extract user and assistant messages."""
    user_messages = []
    assistant_texts = []
    session_id = None
    session_date = None

    try:
        with open(jsonl_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        # If file is large, only process last N lines for performance
        if len(lines) > 500:
            lines = lines[-max_lines:]

        for line in lines:
            try:
                data = json.loads(line.strip())

                # Extract session metadata from first message
                if session_id is None:
                    session_id = data.get('sessionId', 'unknown')
                    timestamp = data.get('timestamp')
                    if timestamp:
                        try:
                            session_date = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
                        except:
                            pass

                msg_type = data.get('type')
                message = data.get('message', {})
                content = message.get('content')

                if msg_type == 'human':
                    # Extract user message text
                    text = extract_text_from_content(content)
                    if text.strip():
                        user_messages.append(text.strip())

                elif msg_type == 'assistant':
                    # Extract assistant text blocks (skip tool_use, tool_result, thinking)
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                text = block.get('text', '').strip()
                                if text:
                                    # Take first 200 chars as highlight
                                    assistant_texts.append(text[:200])

            except json.JSONDecodeError:
                continue
            except Exception:
                continue

        # Fallback to file mtime if no timestamp in data
        if session_date is None:
            session_date = datetime.fromtimestamp(os.path.getmtime(jsonl_path))

        return user_messages, assistant_texts, session_id, session_date

    except Exception as e:
        print(f"Error parsing JSONL: {e}", file=sys.stderr)
        return [], [], None, None


def extract_topics(user_messages, top_n=8):
    """Extract top keywords from user messages."""
    # Combine all user text
    combined_text = ' '.join(user_messages).lower()

    # Split into words, filter by length and stopwords
    words = combined_text.split()
    filtered_words = [
        w.strip('.,!?;:()[]{}"\'-')
        for w in words
        if len(w) >= 3 and w.lower() not in STOPWORDS
    ]

    # Count frequencies
    word_counts = Counter(filtered_words)

    # Return top N
    return word_counts.most_common(top_n)


def find_project_dir(cwd):
    """Convert CWD to project-id format and find project directory."""
    # Replace / with -
    project_id = cwd.replace('/', '-')
    claude_projects_dir = Path.home() / '.claude' / 'projects'
    project_dir = claude_projects_dir / project_id

    if not project_dir.exists():
        return None

    return project_dir


def find_previous_session_file(project_dir):
    """Find the second most recent JSONL file (previous session)."""
    jsonl_files = list(project_dir.glob('*.jsonl'))

    if len(jsonl_files) <= 1:
        # Only 1 or 0 files means no previous session
        return None

    # Sort by mtime, most recent first
    jsonl_files.sort(key=lambda f: f.stat().st_mtime, reverse=True)

    # Return second most recent (index 1)
    return jsonl_files[1]


def write_digest(knowledge_dir, user_messages, assistant_texts, session_id, session_date, topics):
    """Write the digest to _pending_digest.md."""
    threads_dir = Path(knowledge_dir) / '_threads'
    threads_dir.mkdir(exist_ok=True)

    digest_path = threads_dir / '_pending_digest.md'

    # Format date
    date_str = session_date.strftime('%Y-%m-%d %H:%M:%S') if session_date else 'unknown'

    # Build markdown content
    lines = [
        "# Session Digest",
        f"**Session:** {session_id}",
        f"**Date:** {date_str}",
        f"**Messages:** {len(user_messages)} user, {len(assistant_texts)} assistant turns",
        "",
        "## User Messages",
    ]

    for msg in user_messages:
        # Trim to 500 chars
        trimmed = msg[:500]
        if len(msg) > 500:
            trimmed += '...'
        lines.append(f"> {trimmed}")
        lines.append("")

    lines.append("## Assistant Highlights")
    for text in assistant_texts:
        # Already trimmed to 200 chars in parsing
        summary = text.replace('\n', ' ')
        if len(text) == 200:
            summary += '...'
        lines.append(f"- {summary}")

    lines.append("")
    lines.append("## Topics Detected")
    for word, count in topics:
        lines.append(f"- {word} ({count} mentions)")

    # Write to file
    with open(digest_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    return digest_path


def resolve_knowledge_dir_for_cwd(cwd):
    """Resolve knowledge directory using shared resolver."""
    return _resolve_knowledge_dir(cwd=cwd)


def main():
    parser = argparse.ArgumentParser(
        description='Extract session digest from previous Claude Code session'
    )
    parser.add_argument('--knowledge-dir', help='Path to knowledge directory')
    parser.add_argument('--cwd', help='Current working directory', default=os.getcwd())

    args = parser.parse_args()

    try:
        # Resolve knowledge directory
        knowledge_dir = args.knowledge_dir
        if not knowledge_dir:
            knowledge_dir = resolve_knowledge_dir_for_cwd(args.cwd)

        if not knowledge_dir or not os.path.exists(knowledge_dir):
            # Silently exit if no knowledge dir
            sys.exit(0)

        # Verify knowledge store is initialized (has _manifest.json)
        if not os.path.isfile(os.path.join(knowledge_dir, '_manifest.json')):
            sys.exit(0)

        # Find project directory
        project_dir = find_project_dir(args.cwd)
        if not project_dir:
            # Silently exit if no project dir
            sys.exit(0)

        # Find previous session file
        prev_session_file = find_previous_session_file(project_dir)
        if not prev_session_file:
            # No previous session
            sys.exit(0)

        # Check if already processed
        digest_path = Path(knowledge_dir) / '_threads' / '_pending_digest.md'
        if digest_path.exists():
            digest_mtime = digest_path.stat().st_mtime
            session_mtime = prev_session_file.stat().st_mtime
            if digest_mtime > session_mtime:
                # Already processed this session
                sys.exit(0)

        # Parse the JSONL file
        user_messages, assistant_texts, session_id, session_date = parse_jsonl_file(
            prev_session_file
        )

        # Check if session is too short
        if len(user_messages) < 3:
            sys.exit(0)

        # Extract topics
        topics = extract_topics(user_messages)

        # Write digest
        write_digest(
            knowledge_dir,
            user_messages,
            assistant_texts,
            session_id,
            session_date,
            topics
        )

        # Success (silent)
        sys.exit(0)

    except Exception as e:
        # Fail gracefully - log to stderr but exit 0
        print(f"Error in extract-session-digest: {e}", file=sys.stderr)
        sys.exit(0)


if __name__ == '__main__':
    main()
