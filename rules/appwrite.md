# Appwrite gate
Invoke `appwrite-backend` skill FIRST for ANY Appwrite code (TablesDB/Auth/Storage/Functions/Realtime).

## Backend compliance check
Use `api-designer` agent when reviewing Appwrite backend. Agent has project Appwrite MCP tools.

Agent MUST:
1. Grep ALL `Query.select([...])` calls
2. Extract field names
3. Fetch live schema via Appwrite CLI (see `appwrite-backend` skill → `references/appwrite-cli.md` for full command list, e.g. `appwrite databases list-attributes --database-id <id> --table-id <id>`) or project Appwrite MCP as fallback
4. Flag selected fields not in collection attrs
5. Flag missing indexes on queried fields
6. Overall compliance via `appwrite-backend` skill

Guard: only if project uses Appwrite.
