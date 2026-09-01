# Chat Translator

Translates your outgoing chat messages into a language you set, and translates
other players' incoming messages into your language.

You can type into **either** the game's own chat box or the translator's input
bar at the bottom of the screen.

Roblox's chat bar is driven by a CoreScript in a separate Luau VM, so an
executor hook on the game metatable never sees its `SendAsync` call. The
TextBox it reads is reachable though: it is an ordinary GUI under
`CoreGui.ExperienceChat`. The script takes the text and blanks the box before
the CoreScript reads it, which replaces the message without any hook. If that
GUI path is not present, the load message says so and the translator bar is
the fallback.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/algodoo-ipa/claude/gemini-translation-script-85585x/roblox/chat_translator.lua"))()
```

Pinned to a specific commit (does not pick up later changes):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/algodoo-ipa/2ef2084722d3269f4e7856e6c630455f08c19ff0/roblox/chat_translator.lua"))()
```

## If your messages still send untranslated

Check you are typing into the translator bar and not the game's chat box. If
the bar never appeared, the load message says `INPUT BAR FAILED` with the
reason. To inspect the chat setup directly, run the diagnostic:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/aaron1612n-cmd/algodoo-ipa/main/roblox/chat_diagnostic.lua"))()
```

Then type `zzdiag hello` and wait for the `VERDICT:` line. It reports whether
any call in the hooked VM carries your chat text, lists the channels, and
tests that `SendAsync` can still deliver a message.

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
