# PR: Fix `buildPostContent()` to emit proper `{tag: "at"}` elements for @mentions

## Problem

When an LLM response contains `<at user_id="ou_xxx">Name</at>` tags, the current `buildPostContent()` function wraps the entire text — including `<at>` tags — inside a single `{tag: "md", text: "..."}` element. Lark's post message API treats `<at>` tags embedded in markdown text as plain text, not as real @mentions.

**Current behavior:**
- The `<at>` tags are sent as part of the markdown text string
- The `mentions` array in the resulting message is empty
- The `im.message.receive_v1` event is NOT dispatched to the mentioned user/bot
- The mentioned user/bot receives no notification

**Expected behavior:**
- `<at>` tags are extracted and sent as independent `{tag: "at", user_id: "..."}` post elements
- The `mentions` array is correctly populated by Lark
- The `im.message.receive_v1` event fires for the mentioned user/bot
- The mentioned user/bot receives a notification

## Steps to Reproduce

1. Configure an OpenClaw agent that outputs `<at user_id="ou_xxx">BotName</at>` in its response
2. Send the response via the Lark plugin's `buildPostContent()` → post message API
3. Observe the sent message: the `<at>` tag renders as plain text; the target bot/user does NOT receive an `im.message.receive_v1` event
4. Check the message via `GET /open-apis/im/v1/messages/{message_id}`: `mentions` array is empty

## Proposed Change

**File:** `src/messaging/outbound/deliver.js`

```diff
 function buildPostContent(text) {
+    const cleaned = text.replace(/\\"/g, '"');
+    const atRegex = /(<at\s+user_id="[^"]+">.*?<\/at>)/gi;
+    const parts = cleaned.split(atRegex);
+    const elements = [];
+    for (const part of parts) {
+        const m = part.match(/<at\s+user_id="([^"]+)">(.*?)<\/at>/i);
+        if (m) {
+            elements.push({ tag: 'at', user_id: m[1] });
+        } else if (part) {
+            elements.push({ tag: 'md', text: part });
+        }
+    }
+    if (elements.length === 0) {
+        elements.push({ tag: 'md', text });
+    }
     return JSON.stringify({
         zh_cn: {
-            content: [[{ tag: 'md', text }]],
+            content: [elements],
         },
     });
 }
```

### What the change does

1. **Unescape double quotes** (`\"` → `"`): LLM output may contain escaped quotes inside `<at>` tags
2. **Split text on `<at>` boundaries**: Uses a capturing-group regex so the `<at>` tags are preserved in the split result
3. **Classify each segment**: `<at>` matches become `{tag: "at", user_id: "..."}` elements; everything else becomes `{tag: "md", text: "..."}` elements
4. **Fallback**: If parsing yields no elements (empty input edge case), fall back to the original single `{tag: "md"}` behavior

## Test Verification

### Manual API test: `{tag: "at"}` as independent element

Sent a post message via `POST /open-apis/im/v1/messages` with this body:

```json
{
  "content": "{\"zh_cn\":{\"content\":[[{\"tag\":\"md\",\"text\":\"Hello \"},{\"tag\":\"at\",\"user_id\":\"ou_xxx\"},{\"tag\":\"md\",\"text\":\" please check\"}]]}}",
  "msg_type": "post",
  "receive_id": "oc_yyy"
}
```

**Result:**
- `mentions` array contains the mentioned user with correct `id`, `name`, `key`
- `im.message.receive_v1` event fired for the mentioned bot/user
- Notification delivered successfully

### Manual API test: `<at>` inside `{tag: "md"}`

Sent the same text but with `<at>` embedded in the markdown string:

```json
{
  "content": "{\"zh_cn\":{\"content\":[[{\"tag\":\"md\",\"text\":\"Hello <at user_id=\\\"ou_xxx\\\">Name</at> please check\"}]]}}",
  "msg_type": "post",
  "receive_id": "oc_yyy"
}
```

**Result:**
- `mentions` array is **empty**
- No `im.message.receive_v1` event
- No notification

## Impact Analysis

### Breaking changes: None

- Messages without `<at>` tags produce identical output (single `{tag: "md"}` element)
- The `normalizeAtMentions()` function upstream already standardizes `<at>` tag formats before `buildPostContent()` is called; no conflict
- The `cleaned.replace(/\\"/g, '"')` step is safe: escaped double quotes inside markdown text (outside `<at>` tags) are rare and unescaping them has no semantic effect on Lark's markdown rendering

### Edge cases handled

| Case | Behavior |
|------|----------|
| No `<at>` tags in text | Single `{tag: "md"}` — same as before |
| Multiple `<at>` tags | Each extracted as separate `{tag: "at"}` element |
| `<at>` at start/end of text | Empty strings from `split()` filtered by `if (part)` |
| Escaped quotes `\"` in LLM output | Unescaped before parsing |
| Empty/whitespace-only input | Fallback to `{tag: "md", text}` |
| `<at>` with extra whitespace (`<at  user_id=...>`) | Handled by `\s+` in regex |
