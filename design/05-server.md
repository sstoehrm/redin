# The redin server

The host runs an HTTP/WebSocket server on localhost. This is the AI's interface — and also useful for dev tools, remote inspection, and testing.

## Endpoints

```
GET  /frames                — list all named frames
GET  /frames/:id            — read a frame subtree by element id
PUT  /frames/:id            — inject/replace a frame subtree at element id
GET  /state                 — read full app-db
GET  /state/:path           — read a nested path in app-db
POST /events                — dispatch an event
GET  /bindings              — read all active bindings
GET  /aspects               — read the current aspect map
PUT  /aspects               — replace the aspect map (live theme swap)
WS   /ws                    — stream: frame updates, events, state changes
```

## AI interaction patterns

**Read what the user sees:**
```json
GET /frames
→ {"frame": ["vbox", {"aspect": "surface"}, ...], "bind": [...]}
```

**Inject UI into a target area:**
```json
PUT /frames/ai-panel
← {"frame": ["vbox", {}, ["text", {"aspect": "heading"}, "suggestion"], ...]}
```

The app reserves a frame slot (e.g. `:id :ai-panel`) where the AI can inject content. The AI writes pure frame data — same format as the app itself. The renderer draws it like any other frame.

**Dispatch interaction:**
```json
POST /events
← {"event": ["counter/inc"]}
```

**Watch live:**
```
WS /ws
→ {"type": "frame", "data": [...]}
→ {"type": "state", "path": ["counter"], "value": 43}
→ {"type": "event", "data": ["counter/inc"]}
```

## Frame injection rules

- AI can only write to elements marked with `:ai true` in the frame
- Injected frames go through the same aspect system (AI uses the app's design tokens)
- Injected frames can include bindings (AI can make its content interactive)
- The app decides where AI panels live — the AI fills them
