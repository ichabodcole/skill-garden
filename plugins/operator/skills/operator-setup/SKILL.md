---
name: operator-setup
description: >
  Authenticate to Operator (the Operator Editor MCP server) and establish a
  reusable session before using any Operator MCP tools — reading, writing,
  browsing, searching, or triaging documents. This is the gateway skill for all
  Operator access: it handles the `.operator` credential file, API-key auth,
  session reuse (24h), and re-authentication when a session expires. Use
  whenever the user wants to work with Operator at all, or hits an auth/session
  error. Triggers when the user says "use Operator", "connect to Operator", "log
  into Operator", "authenticate Operator", "read/write/browse my Operator docs",
  "set up Operator", "my Operator session expired", or mentions "Operator" or a
  `.operator` file for the first time in a session.
---

# Operator Setup

**Operator Editor** is a document editor with MCP server integration for reading
and writing documents.

## When to Use

This is the **gateway skill for all Operator access** — run it (or confirm a
live session already exists) before any Operator MCP tool call. Activate when:

- The user wants to use Operator at all — read, write, browse, search, or triage
  documents
- The user mentions "Operator" / the Operator Editor / a `.operator` file for
  the first time in a session
- Authentication or a session is needed, or an existing session has expired
- The user needs help setting up their `.operator` configuration

## Configuration File

The `.operator` file stores credentials in the working directory:

```
OPERATOR_API_KEY=mcp_xxx...
OPERATOR_SESSION_ID=abc123...
```

## Authentication Flow

1. **Check for `.operator` file**
   - If absent: Offer to create it (see "First-Time Setup" below)

2. **Check for cached session ID**
   - If `OPERATOR_SESSION_ID` exists, try using it directly
   - Sessions are valid for 24 hours

3. **If session is expired or missing**
   - Authenticate using `OPERATOR_API_KEY`
   - Update `.operator` file with the new `OPERATOR_SESSION_ID`
   - This avoids creating unnecessary new sessions

## First-Time Setup

If no `.operator` file exists, explain the options:

1. Provide API key directly for this session only (no file created)
2. Create `.operator` file to persist credentials

If they choose option 2, be explicit: "I'll create a `.operator` file with your
API key and add it to `.gitignore` to keep it out of version control." Get
confirmation before creating files.

## Session Reuse

Always prefer reusing an existing session:

- Same project = same session (within 24 hours)
- Only re-authenticate when the session is expired
- Update the file with new session ID after re-authentication

## After Setup

Once authenticated, use the MCP tools directly - their descriptions provide all
operation details.
