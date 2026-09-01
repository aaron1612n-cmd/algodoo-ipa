# Chat Translator

Translates your outgoing chat messages into a language you set, and translates
other players' incoming messages into your language.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/algodoo-ipa/claude/gemini-translation-script-85585x/roblox/chat_translator.lua"))()
```

Pinned to a specific commit (does not pick up later changes):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/algodoo-ipa/2ef2084722d3269f4e7856e6c630455f08c19ff0/roblox/chat_translator.lua"))()
```

## If your messages still send untranslated

Some games ship a custom chat GUI instead of Roblox's default one, and some
executors cannot see the send at all. Run the diagnostic to find out which:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/algodoo-ipa/main/roblox/chat_diagnostic.lua"))()
```

Then type a message containing `zzdiag`. It prints yellow `[DIAG]` lines:

- a `MATCH method=... obj=...` line names exactly what carries your chat to
  the server, so the translator can be pointed at it.
- no `MATCH` line means the send happens in the CoreScript VM, outside the
  metatable your executor hooked. A namecall hook cannot intercept it there,
  and the translator needs its own input box instead.

## Commands

Typed into normal chat. They are swallowed and never sent to the server.

| Command | Effect |
| --- | --- |
| `>ja`, `>es`, `>pt-br`, ... | Set outgoing language and enable outgoing translation |
| `>d` | Disable outgoing translation |
| `>in en` | Set incoming language and enable incoming translation |
| `>in off` | Disable incoming translation |
| `>tr` | Show current status |
| `>help` | List commands |

## Requirements

Outgoing translation needs an executor exposing `getrawmetatable`,
`setreadonly` and `getnamecallmethod`, because the only reliable way to stop
the original message is to intercept `TextChannel:SendAsync` at the send
layer. If those are missing the script warns on load and incoming translation
still works.

Re-running the loadstring is safe: state is stored in `getgenv()` and the
metamethod hook is installed only once.
